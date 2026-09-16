# Write safety and provenance

Three concerns that make a write survive a retrying client, a concurrent writer,
and an auditor's question afterwards.

Source files:

- `app/controllers/concerns/idempotent_create.rb` — replay-safe creates
- `app/controllers/concerns/stale_object_retry.rb` — optimistic-lock retry
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
`ThumbnailCreationJob` and `DerivativeCreationJob` both attaching Delegates to
the same FileSet — Valkyrie raises `StaleObjectError` on the loser.

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
`advanced_form` or `xml_editor`. **Atlas stores it verbatim and never branches on
it, so a new surface needs no Atlas change.** It is capped at
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
