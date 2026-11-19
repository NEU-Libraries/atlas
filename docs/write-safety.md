# Write safety and provenance

Three concerns that make a write survive a retrying client, a concurrent writer,
and an auditor's question afterwards.

Source files:

- `app/controllers/concerns/idempotent_create.rb` — replay-safe creates
- `app/controllers/concerns/stale_object_retry.rb` — optimistic-lock retry
- `app/lib/stale_retry.rb` — the same retry, for services
- `app/lib/advisory_lock.rb` — serializing a lazy first build, the METS rebuilds, and the envelope, MODS and Darwin Core writes
- `app/controllers/concerns/auditable.rb` — provenance emission
- `app/controllers/audit_events_controller.rb` — the history surface
- `app/services/audit_event_writer.rb` — the row writer

Atlas runs **no background jobs**; orchestration is Cerberus's. Every rule here
therefore has to hold inside one request.

## Replay-safe creates

Cerberus's per-record Solid Queue jobs send an `Idempotency-Key` header, so that
an Atlas-side commit followed by a Cerberus crash does not produce a duplicate
resource on retry.

Controllers wire the three helpers explicitly from the create action:

```ruby
def create
  if (record = find_idempotency_record(Work))
    @work = Work.find(record.resource_noid)&.decorate
    return render_idempotent_resource(@work)
  end
  @work = WorkCreator.call(parent_id: params[:collection_id])
  record_idempotency_key!(@work.noid, Work)
end
```

**The dispatch stays in the action body** rather than a `before_action` plus
class macros, so a first-time reader of the controller sees the whole flow in one
place.

### The key is scoped per resource class

That is what lets one batch-load row use one key for the Work it creates and
again for that Work's Blob — two operations, so two records.

**The scope is per class, not per action.** A caller that sent one key to both
`POST /files` and `PATCH /files/:id` would still see the second treated as a
replay of the first.

### The replay response

| Resource state | Response |
|---|---|
| Missing (hard-deleted) | `head :gone` |
| Tombstoned | `:show` with 410 |
| Present | The given view, `:create` by default |

The FileSet attach replay passes `:update`, because the idempotent operation
there is a PATCH rather than a POST.

### Bookkeeping never fails the request

`record_idempotency_key!` swallows a lost uniqueness race and logs it. **By the
time it runs, the resource is already persisted in Postgres, Solr and OCFL**, so
raising would report a create that did in fact land as an error — and the caller
would retry it into a second copy.

**A transaction would not help.** The Solr and OCFL writes are outside it, and a
rollback would leave a phantom index entry pointing at nothing.

One failure still raises: a validation error on anything but the key is Atlas's
own bug rather than a race, and must stay loud.

## Optimistic-lock retry

When two callers PATCH shared resource state inside one lock window — Cerberus's
`DepositDerivativesJob` and `IiifAssetsJob` both attaching Delegates to the same
FileSet — Valkyrie raises `StaleObjectError` on the loser.

**For an append-style mutation the loser's intent is still valid against fresh
state**, so rescue-reload-retry converges instead of failing. This is the pattern
the Valkyrie wiki documents under "Optimistic Locking".

### Only wrap a genuinely idempotent action

Re-applying the same change against reloaded state must yield the same result.

| Wrapped | Not wrapped |
|---|---|
| `update_thumbnails`, `update_image_derivatives`, `complete` | The generic metadata `update`, `tombstone`, `restore`, permission removals |

For the right-hand column, **silent retry could clobber a concurrent caller's
genuinely different intent.** Those surface the conflict through the 409 envelope
instead — see [`error-contract.md`](error-contract.md).

### The reload must happen inside the retried block

The `find` that re-reads the resource, and the FileSet it references, with a
fresh `optimistic_lock_token` **is** the reload half of the pattern. Placing it
outside the block would re-PATCH with the same stale token and re-raise
immediately.

### The backoff is bounded and jittered

`RETRY_BASE_SECONDS` is 50ms and `RETRY_MAX_ATTEMPTS` is 3. With full jitter and
exponential `2**n`, the two backoff sleeps before exhaustion spread up to roughly
100 + 200 = 300ms worst case. **Small enough to stay invisible in an API timing
budget, large enough that two retriers stop colliding deterministically.**

Full jitter is the AWS "Exponential Backoff And Jitter" recommendation: it gives
the best decorrelation between concurrent retriers, avoiding the
lockstep-collision thundering herd deterministic backoff would cause.

Logging is noisy on purpose. **The point of retrying is to make transient
conflicts invisible to callers, but they must stay visible to an operator
debugging a misbehaving coordinator.**

### Services retry through `StaleRetry`

A controller's retry covers only the writes inside its block. Many writes happen
deeper, in a service, after the write the caller asked for has landed. A
conflict there used to answer 409 for a change that had in part happened.
`StaleRetry` gives services the same budget and backoff in two forms.

**`StaleRetry.run` retries one write with a reload.** The block receives the
attempt number and must reload what it saves when the number is above 0. Use it
only for a write that carries no intent of its own beyond what is reloaded, so a
retry cannot overwrite a concurrent caller's change:

| Write | Why a retry is safe |
|---|---|
| The METS rebuilds, `WorkMETSRebuilder` and `METSRebuilder` | Derived from current state. Two rebuilds of one owner never overlap (see below), so the retry covers only other writers to the METS Blob or the structural FileSet |
| Attaching a new Blob or Delegate to its FileSet | Appending one id is idempotent. Without the retry, the saved Blob or Delegate is attached to nothing, and the caller's retry saves a second one |
| Reclassifying a FileSet after a revision | Setting the same type again is idempotent |
| The handle save and the MODS identifier in `HandleMinter` | The handle is registered by then ([`handles.md`](handles.md)) |
| Detaching a purged resource from a linking Work | Dropping one id is idempotent, and the purge is already recorded |
| The re-save after a MODS upload | It carries no attribute of its own; it re-projects Solr |
| Restoring a tombstoned Darwin Core FileSet on upload | Clearing a tombstone is idempotent |

**`StaleRetry.settle` gives up quietly.** It is for a derived write that
follows the write a caller asked for: the METS rebuild after an upload, a
revision, a new page or a page delete. A conflict that outlasts the retries is
logged rather than raised. Raising would answer an error for an upload or delete
that landed, and a caller's retry would send a multi-gigabyte file again just to
reach the idempotent replay. The METS stays stale until the FileSet or Work is
next written.

### A lazy first build is serialized

A Work's structural FileSet and METS Blob, a FileSet's METS Blob and a Work's
Darwin Core FileSet and Blob are built on first use. **Two first builds at once
would each find nothing and each build**, leaving two FileSets or two Blobs for a
read to pick between. That happens when `/complete` races a page created in the
same deposit.

So each first build holds `AdvisoryLock` on its owner and checks again under the
lock. The second build takes the Blob the first one made. A session lock and not
a transaction, because the build writes Solr and OCFL too, which no rollback
could undo. The lock waits under the 30-second statement timeout
([`availability.md`](availability.md)).

### Rebuilds of one METS run one at a time

Several triggers rebuild the same METS at once. `/complete`, a page added to or
removed from a completed Work, an upload, a revision and a Blob delete each
rebuild a Work's METS or a FileSet's. During a deposit, Cerberus runs its jobs
for one Work in parallel, so two of these overlapping is normal traffic.

**Two rebuilds that overlap can lose a page, not just a lock race.** Each reads
the pages, builds the XML and writes it. If the rebuild that read first writes
last, its XML omits a page the other one saw, and no error is raised. A
rebuild that loses the Blob save instead leaves an OCFL version that no Blob
lists ([`binaries.md`](binaries.md)).

So each rebuild holds the same `AdvisoryLock` as its owner's first build:
`work_mets` for a Work, `mets` for a FileSet. It reloads the owner under the
lock, so a rebuild that waited builds from what the previous one wrote. When
the XML matches what is stored, it writes nothing. The rebuild stays
synchronous, so when `/complete` answers, the METS lists the pages present at
that moment.

Three facts keep the lock safe:

- **The first build nests inside the rebuild.** A rebuild that finds no METS
  Blob takes the same lock again in `create_mets_blob`. A Postgres session
  advisory lock is re-entrant within one session, and `AdvisoryLock.hold` pairs
  every lock with its unlock, so the nested hold neither blocks nor leaks.
- **No path holds two of these locks.** A Work rebuild never starts a FileSet
  rebuild, and a FileSet rebuild never starts a Work rebuild. The structural
  FileSet a Work's first build creates is not a page, so it rebuilds nothing.
  Two locks taken in opposite orders could deadlock, so a change that nests
  `work_mets`, `mets` or `darwin_core` must take a Work's lock before a
  FileSet's.
- **The lock is held briefly.** A rebuild takes about 1.2 ms per page: 0.7
  seconds for 500 pages and 2.5 seconds for 2,000, measured in the test stack.
  A waiter gives up at the 30-second statement timeout, which needs a queue of
  rebuilds well past 20,000 pages. Each waiter holds its database connection
  while it waits.

The specs in `spec/services/mets_single_writer_spec.rb` race two rebuilds in
threads with their own connections, because transactional tests share one
connection, and the lock is re-entrant within it.

### Envelope, MODS and Darwin Core writes run one at a time

The METS failure has the same shape in three more places. Each write derives
one copy from state it read, and a slower writer can store an older state
last, with no error:

| Write | What overlapping writes could leave | Lock |
|---|---|---|
| `PreservationEnvelopeWriter` | Disk holding an older graph or older permissions. A rebuild from disk would restore them | `envelope` |
| `Modsable#mods_xml=` | The XML holding one upload and the JSON access copy holding the other | `mods` |
| `darwin_core_xml=` and `tombstone_darwin_core!` | The same split between the Darwin Core XML and its JSON row | `darwin_core` |

**The envelope writer reloads the resource under its lock** and serializes the
reloaded copy, not the one its caller passed. Every caller writes the envelope
right after a save, so the reload writes the state that was saved. It skips a
resource that no longer exists, because a write would recreate the OCFL object
a purge removed. **An envelope whose bytes the head already holds writes
nothing**, as a METS rebuild does, so a writer that waited cuts no empty version
([`resource-graph.md`](resource-graph.md)).

**A MODS write holds its lock across the XML, the Blob save and the JSON row.**
It reads the Blob under the lock, so a write that waited saves a current lock
token and raises no conflict. A write built from the stored document, such as
the handle identifier `HandleMinter` adds, goes through
`Modsable#update_mods_xml`, which also holds the lock across the read. A
concurrent upload then lands wholly before that read or after that write.

**The Darwin Core write widens its first-build lock to the whole write**, and
the tombstone takes the same lock, so a restore and a tombstone cannot cross.

**The locks nest in one order.** Every one of these writes ends in an envelope
write, so `envelope` comes after the others, and the envelope writer takes no
other lock except `index`, which is the innermost (see the next section). No
path holds `mods` together with `work_mets`, `mets` or
`darwin_core`: the FileSets a MODS or Darwin Core first build creates are
metadata FileSets, so they build no METS. The order is therefore `work_mets`,
`mets` or `darwin_core`, then `mods`, then `envelope`, then `index`. A change
that nests them must keep it, or two writers can deadlock.

**The envelope lock is held for milliseconds.** An envelope write took 4 to 14
ms in the test stack, also on a Work with 1,000 pages: a Work's envelope does
not list its FileSets, because each FileSet names its Work.

The specs in `spec/services/envelope_mods_single_writer_spec.rb` race each pair
of writers in threads, as the METS specs do.

### Solr writes of one resource run one at a time

Valkyrie's `CompositePersister` saves to Postgres, then to Solr. Two saves of
one resource are ordered in Postgres by the optimistic lock, but nothing orders
their Solr writes. If the save that reached Postgres first reaches Solr last,
search, facets and OAI serve the older state, and no error is raised. A reindex
from a copy read before a later save had the same effect.

So `Valkyrie::Persistence::OrderedIndexPersister` takes the composite's place.
After the Postgres save, it holds an `index` lock for the resource, reads the
resource from Postgres under the lock, and indexes that copy. A write that
waited indexes the latest save, not its own. `Atlas.reindex` goes through the
same method, so it also ignores the copy its caller passes, except for the id.
A resource that no longer exists indexes nothing, and a delete removes the
document under the same lock, so a late reindex cannot bring back a purged
document.

Three facts keep the lock safe:

- **`index` is the innermost lock.** No indexer takes a lock or saves, so the
  order above becomes `work_mets`, `mets` or `darwin_core`, then `mods`, then
  `envelope`, then `index`. An envelope write can reach `index` through the
  storage footprint reindex.
- **It costs about 4 ms per save.** An ordered Solr write took 38 ms against
  34 ms for a plain one in the test stack: the lock and one Postgres read. The
  lock is held for the Solr write.
- **A save inside an open transaction indexes its own uncommitted row.** Another
  session reads the committed row under the lock, so its Solr write can land
  after. No resource save runs inside a transaction today; `ResourcePurger`'s
  transaction holds only its audit and purge rows.

A Solr write that fails after its Postgres save still leaves the document
behind. The health check reports that as `index_stale`
([`work-health.md`](work-health.md)).

The specs in `spec/services/ordered_index_spec.rb` race two saves of one Work in
threads, as the METS specs do.

### `complete` finishes its tail before it answers 409

`complete` makes its writes in order: the Work saved with `in_progress: false`
(inside `with_stale_object_retry`), the METS rebuild, the handle, and the
`complete` audit row. Once the first write lands, the Work is complete, and
nothing undoes that. So a METS conflict that outlasts the rebuild's own retries
is held, the handle is minted and the audit row written, and only then does the
action raise it as a 409.

**This 409 does not mean nothing changed.** The OpenAPI description says so.
A second call finishes the METS and mints nothing new, because `HandleMinter`
skips a Work that already has a handle. Without the hold, the Work would be
public and complete with no handle and no audit row. It would also not appear
on the in-progress list, so nothing would flag it.

## Provenance emission

The structural mutations — create, reparent, link and unlink — already emit from
their service objects. `Auditable` closes the content, metadata, lifecycle and
file gap, giving the three resource controllers and the blob controller a
one-line emit at each save point.

It closes over the actor plumbing the controllers already carry: `@current_user`
as actor and `@on_behalf_of` as attribution target, both set in
`require_auth`.

**The actor is the authenticated principal, not the `User:` header.** The
signed-assertion relay does not send that header — see
[`authentication.md`](authentication.md).

**`audit!` no-ops for a guest.** A guest carries no provenance, and `actor_nuid`
is `NOT NULL`, so guest reads and unauthenticated paths write nothing.

### The MODS upload payload

`source` names the write path and is matched **exactly** by downstream renderers,
so the editing surface rides beside it in `origin` rather than overloading it.

`origin` is whatever the caller asserts — Cerberus sends `metadata_form`,
`advanced_form`, `xml_editor`, `xml_loader` or `deposit`, and sends none for a
showcase it provisions. The list is Cerberus's to grow. **Atlas stores it verbatim
and never branches on it, so a new surface needs no Atlas change.** It is capped at
`ORIGIN_MAX_LENGTH` (64) because it is free text from the wire landing in a jsonb
column.

The key is omitted when the caller sends nothing, which is what every event
recorded before the field existed looks like.

### The metadata PATCH writes permissions only

`audited_metadata_update` applies the params, persists, re-emits the preservation
envelope, and writes the provenance rows. It is extracted because Works,
Collections and Communities drive it identically.

**Descriptive fields are not writable here.** Title and description keys are
silently ignored. The only MODS write path is the caller-assembled raw
`mods_xml=` binary upload; descriptive merges belong to the client, not Atlas.

`resource.alternate_ids = metadata['noid']` is a **test-only affordance**, gated
on `Rails.env.test?`.

### Why the ACL guard lives in `apply_metadata_params`

This is the single funnel every resource type's ACL write passes through, and
**the only place carrying both the acting user and the pre-edit state.** So it is
where `PermissionsWriteGuard`'s two rules apply — see
[`authorization.md`](authorization.md).

`before_acl` is captured **before** reassignment, so the audit row can record
before and after, and so a no-op write can be detected.

### No-op suppression

A permissions write whose effective ACL is unchanged — re-saving the Permissions
tab without edits, or re-applying an inherited ACL — is a non-event. Comparing
the **post-setter** normalized ACLs, including the staff auto-prepend, suppresses
a spurious "Updated · Permissions" row.

`acl_equivalent?` sorts array values before comparing, because **a group list
that differs only in order is the same grant.** The payload still records the
ACLs in their stored order.

### Embargo release rows

An embargo lapsing is not a write, so no controller runs at the boundary and
nothing would record it. `POST /embargoes/release` closes that gap:
`EmbargoReleaseRecorder` writes one `release_embargo` row per lapsed Work.
Cerberus calls it nightly from its own recurring jobs, because Atlas runs no
scheduler.

**The history holds stored rows only.** A client must not draw an "Embargo
released" line from the release date at render time. A derived line mixes what
was recorded with what is inferred, and it would vanish if a lapsed embargo were
later removed.

The rules the recorder keeps:

- **The row is dated to the release moment**, the start of the release day in
  Eastern time (`Permissions.embargo_released_at`), not to the call. A late or
  missed run therefore cannot misdate the history.
- **It is keyed on the release date**, not the Work. Repeating a call writes
  nothing, and a Work embargoed again earns a second row when that embargo
  lapses.
- **An embargo set after its own release moment gets no row.** Cerberus refuses
  a past date, but Atlas accepts one from any API client. A row dated before the
  change that set the embargo would put the history out of order. Only a
  `permissions` row whose `embargo` differs between `before` and `after` counts
  as a change.
- **Solr only nominates.** The candidates come from a range query on
  `embargo_release_date_dtsi` over the last seven days, or from `since`. Solr's
  midnight UTC passes hours before the Eastern boundary, and the index is
  derived, so the Postgres resource decides.

The actor is the calling principal, and `event_source` is `job` when that
principal is `:system`.

**A released Work is re-projected.** The index left its full text out while the
embargo held, and a lapse writes nothing that would re-index it, so the
recorder calls `Atlas.reindex` on each Work it writes a row for. It is a Solr
write only: no Postgres change and no lock bump.

## The history surface

`AuditEventsController#index` **deliberately does not load the Valkyrie
resource.** History rows exist for tombstoned and destroyed resources too, and
**the audit trail must survive deletion of what it audits.**

The lookup is keyed on the Valkyrie UUID the writer stores in
`AuditEvent#resource_id`, so the URL's NOID resolves to a UUID before scoping,
falling back to the raw param for already-destroyed resources and legacy
NOID-literal rows.

A `TODO` in the file tracks persisting the NOID alongside the UUID at write time,
which would retire that fallback.

**Admins read any history; delegated admins read a Work's, a Collection's or a
Community's,** through `:read_history` and then `:read` on the resource. The
argument for that gate is in [`authorization.md`](authorization.md#the-devolved-admin-tier).
The lookup still does not depend on the resource: `Resource.find` is used only
to authorize and to resolve the UUID.

### Session-scoped events

`POST /audit_events` records an event with no resource to hang on: impersonation
start and end.

The session lifecycle lives in the calling app, and **view-as performs no
resource writes at all**, so there is no mutation to attach the event to.

**Principals travel in the body rather than being inferred from headers**,
because an `impersonation_ended` emit fires as the session is torn down.

`mode` — `acting_as` or `view_as` — has no dedicated column. It is a property of
the session rather than the content graph, so it rides in the jsonb payload.

**Read the body's `action` from `request_parameters`, not `params`.**
`params[:action]` is reserved by the router and resolves to the controller action
name, shadowing the emit's own action field.

Admin-gated: `:admin` reaches it through `manage :all`, and the devolved-admin
tier through `apply_admin_delegate_abilities`. Both impersonation modes call this
before establishing a session, and **Atlas trusts Cerberus's own admin-only gate
on acting-as** to decide which mode a delegate may reach. Every other principal —
`:system`, `:guest`, standard humans — is denied 403.
