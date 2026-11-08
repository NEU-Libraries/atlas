# The resource graph

The shape of the content graph, the endpoints that traverse it, and the on-disk
envelope that lets it be rebuilt without Atlas.

Source files:

- `app/models/work.rb` — the Work's attributes and the association edges
- `app/models/concerns/relationships.rb` — containment and traversal
- `app/models/concerns/preservable.rb` — the on-disk envelope
- `app/controllers/resources_controller.rb` — the generic resolver and traversals
- `app/controllers/concerns/reparentable.rb` — moving a node

The batching behind the traversals is [`read-performance.md`](read-performance.md).

## A tree with a DAG overlay

`Community → Collection → Work → FileSet → Blob` is the structural backbone, and
it is a strict **tree**: `a_member_of` on a Work is **scalar**, because a Work
lives in exactly one Collection.

`a_linked_member_of` is the overlay: a Work can be a linked member of additional
Collections without duplicating the object.

**It is leaves-only.** Only Works carry it, so the collection and community
backbone stays a strict tree and **cycles are structurally impossible.**

**It adds placement, never permission.** The Work keeps its single ACL.

## A typed `find` answers only its own type

A NOID names a resource of any type, and the underlying Valkyrie lookup returns
whatever the id names. `Resource.find` keeps that behaviour: it is the generic
resolver. A subclass's `find` — `Work.find`, `FileSet.find`, `Blob.find` and the
rest — returns `nil` when the id names a resource of another type.

So a wrong-type id reads exactly like an unknown id, and every typed route
answers it with the 404 it already gives an unknown id. The typed controllers
depend on this for safety as well as for correct reads. Their writes authorize
at the class level (`:destroy, FileSet`), so without the type check
`DELETE /file_sets/<a Collection id>` would purge the Collection and skip the
`has_children` guard that `DELETE /resources/:id` applies.

Code that genuinely accepts any type must call `Resource.find`.

## Work-to-Work associations

`ASSOCIATION_TYPES` is five typed, directed edges: `is_codebook_for`,
`is_figure_for`, `is_instructional_material_for`,
`is_supplemental_material_for`, `is_transcription_of`.

**The subordinate Work stores the edge.** The other end is read back with
`find_inverse_references_by`, so **the reverse edge is never stored and can never
drift out of step with the forward one.**

### Why five attributes and not one encoded string

Two reasons:

1. `find_inverse_references_by` needs a real property to query. It cannot read a
   type out of `"codebook_for:abc123"`.
2. These are v1's own predicate names, so a migration maps one to one.

**The cost is that a sixth relationship type needs an Atlas release.** The
vocabulary has not changed since v1.

## The Work lifecycle flags

| Attribute | Default | Who writes it |
|---|---|---|
| `in_progress` | `true` | Cerberus's bulk-deposit jobs leave it true until every expected child is deposited, then flip it at `POST /works/:id/complete` |
| `incomplete` | `false` | Cerberus sets it from a give-up handler and clears it when a later run of the same job succeeds |
| `incomplete_reason` | nil | Cerberus, as an opaque machine token |

`in_progress` is indexed so `/works?in_progress=true` can find stuck deposits.

**`incomplete` flags and never hides.** A record with its file, title and
metadata but one missing derivative is degraded rather than broken, so it stays
readable. Clearing on a later success makes the state self-healing.

**`incomplete_reason` is deliberately not validated.** The vocabulary belongs to
Cerberus, the only writer, so a token added in a Cerberus job must not need an
Atlas release to be accepted.

## Which derived fields reach the preservation envelope

This is the distinction the preservation-first principle turns on, and these
attributes land on different sides of it.

| Attribute | In the OCFL envelope? | Why |
|---|---|---|
| `handle` | **Yes**, schema v5 | An external Handle service holds the other half of the binding and the outside world cites it. **Nothing in the repository can re-derive it**, so a rebuild that lost it would break every outside citation. |
| `full_text` | No | A regenerable search aid, re-sent on any re-ingest. Postgres only, so `FullTextIndexer` re-reads and re-projects it on every reindex. |
| `derivative_permissions` | No | An access policy: Atlas enforces it on Blob bytes, and Cerberus and the IIIF layer on image tiers. TODO: decide whether an enforced policy belongs in the envelope, as `read` does. |
| `tombstoned_at`, `tombstoned_by`, `tombstone_reason` | **Yes**, schema v7, as one `tombstone` block | A tombstone is a person's decision that nothing else records. A rebuild that lost it would bring tombstoned objects back into view, and drop the removal note the library's removal policy requires. |

`full_text` is omitted for the same reason the fungible thumbnail derivatives
are: **it can be made again.**

### `derivative_permissions` is a JSON string, not a Hash

**The metadata adapter collapses single-element array values.**
`{"small" => ["public"]}` round-trips as `{"small" => "public"}`, which would
corrupt the group-set arrays. So the map is stored JSON-encoded and read through
`TierVisibility`, never raw. See [`authorization.md`](authorization.md).

## The envelope schema

`Preservable` writes `relationships.json` and `permissions.json` into each
resource's own NOID-keyed OCFL object. **The bus-factor test: a librarian with
disk access alone can rebuild the resource graph and the ACLs without Atlas,
Postgres or Solr.**

`ENVELOPE_SCHEMA_VERSION` is 7, and each bump records one decision:

| Version | Change |
|---|---|
| v1 → v2 | `depositor` became a single NUID string (the intellectual owner); added `proxy_uploader` and `edit_users`, which v1 carried under `depositor` |
| v2 → v3 | Added `position` — FileSet page order within a multipage Work, null elsewhere |
| v3 → v4 | Added `associations` — the typed Work-to-Work edges, keyed by predicate |
| v4 → v5 | Added `handle` |
| v5 → v6 | Added a Blob's `language`, `track_label` and `revision_filenames` |
| v6 → v7 | Added `tombstone` — `at`, `by` and `reason` while tombstoned, null while live |

**`position` is additive even though the Work-level METS structMap is the
canonical record of order.** It keeps each FileSet's own OCFL object
self-describing in isolation.

**`associations` has to survive on disk** because each edge is a human judgement
about two objects that nothing else in the repository records and no job can
derive again.

**`a_linked_member_of` is deliberately absent.** A linked membership is a
discovery convenience a Set recipe can express again, not an assertion that
exists nowhere else.

### A write to an envelope field rewrites the envelope

A persister save changes Postgres and Solr only. **Any write that changes a
value the envelope carries must call `write_preservation_envelope!` after it,**
or disk keeps the old value and a rebuild restores it. The minter does this
for `handle`, the reparenter for `a_member_of`, the association services for
`associations`, and tombstone and restore for `tombstone`. `GET
/works/{id}/health_check` reports a Work whose envelope has drifted as
`envelope_stale`, naming the keys that differ ([`work-health.md`](work-health.md)).

A Derivative FileSet is the exception: it holds regenerable Delegates, so
`FileSetCreator` writes it no envelope at all (`Classification.preserved?`).

## A minted NOID never lands on an existing object

Every resource's OCFL object is keyed by its NOID, and the adapter writes a
version into whatever object already holds that key. So a NOID handed out twice
appends a new resource's versions to someone else's object: one object then
holds two unrelated histories, and nothing on disk says where one ends.

The minter keeps its position in Postgres (`minter_states`). That makes it the
one piece of Postgres a rebuild cannot recover from disk, and anything that
winds the table back, such as a database wipe or a restore from an older
backup, makes it reissue NOIDs it has already used.

**So the minter passes over any NOID whose OCFL object already exists.**
`config/initializers/noid_rails.rb` sets noid-rails' `identifier_in_use` hook to
`NoidInUse`, which asks the adapter's `object_exists?`, one existence check per
storage root, and the minter draws again. Both minting call sites,
`Resource`'s default `alternate_ids` and `Compilation`, go through it; a
Compilation owns no object, but sharing the check keeps the namespace unique.

- **Each NOID passed over is logged as a warning.** One is a coincidence worth
  a look; a run of them means the minter state was rewound.
- **There is no cap.** The hook sees one candidate at a time and cannot tell
  where a mint begins, and the loop ends as soon as a candidate has no
  directory on disk.
- **A reset still purges storage** (see [`availability.md`](availability.md)).
  The guard is for the cases no reset covers.

**The minter also passes over a purged NOID.** A purge deletes the OCFL object,
so the existence check alone would hand the NOID out again. Its handle and its
citations outlive the purge, and a reissued NOID would send every one of them to
unrelated material. `NoidInUse` therefore answers true for any NOID in
`purged_identifiers`, and logs it the same way.

## A purged ID answers 410, not 404

`ResourcePurger` writes one `purged_identifiers` row for every NOID it removes:
the resource and each of its FileSets and Blobs, with the type, the time and the
acting NUID. It writes them in the same transaction as the audit row and before
anything is deleted. Unlike the audit row, the rows are written when no actor is
known, because they answer reads rather than record who acted.

`GET /works/:id`, `/collections/:id` and `/communities/:id` answer a NOID that
does not resolve from these rows. If a row of that type exists, the answer is
`410` with an ID-only stub (`WorkPurged`, `CollectionPurged`,
`CommunityPurged`); otherwise it stays `404`. So a reader who follows a kept
handle learns the item was removed, not that it never existed.

- **The stub carries the ID, `purged` and `purged_at`, and nothing else.** A
  purge is the stronger act than a tombstone, taken because the record itself
  must go, so no title survives it.
- **The stub has no `error` key.** atlas_rb raises `TombstonedError` for a 410
  whose `error` is `tombstoned`; without the key, `find` returns the stub.
- **The lookup follows `authorize!`,** as the nil check always has, so a purged
  ID answers the same 410 to every caller who passes authentication.
- **Only these three routes answer 410.** A purged FileSet or Blob has a row, so
  its NOID is never reissued, but `/files/:id` and the other routes keep `404`.
- **The rows cannot be rebuilt from disk,** because the purge deleted the object
  that would have shown it. Like `minter_states`, they are Postgres state a
  rebuild from disk does not recover. A reset clears them with every other table.

## Page order is a total order

`Work#page_file_sets` sorts by position ascending, unordered (nil) last, with a
creation-order tie-break. **That is a total order even over legacy or unordered
data.**

It is shared by `works#file_sets` and the Work-level METS structMap, **so the
runtime read and the preservation record cannot disagree.**

## Work-level METS lives in a sibling FileSet

`Work#mets_blob` overrides `Metsable`'s flat `member_ids` storage, which fits a
FileSet but not a Work: **a Work has no `member_ids`, and its children stay
exclusively FileSets.** So the METS Blob hangs off a sibling
`:structural_metadata` FileSet, the same shape the descriptive metadata uses.

`create_mets_blob` runs lazily at the first METS write, which is `/complete`. So
**existing Works need no backfill, and a never-completed Work never grows one.**

## `ResourcesController`

`GET /resources/:id` is the generic NOID resolver — it 302-redirects to the typed
endpoint.

### What the resolver covers, and the two types it names explicitly

Resolution runs through `Resource.find`, a Valkyrie query, so the resolver
answers for the Valkyrie-backed types only: Work, Collection, Community,
FileSet, Blob, Delegate and Person. A Compilation is an ActiveRecord row
([compilations.md](compilations.md)), so `/resources/:id` **404s on a
Compilation NOID** even though `/compilations/:id` serves it. A client holding
nothing but a NOID cannot tell that 404 from an unknown id.

Two of the seven cannot reach the polymorphic `redirect_to`, so `#show` names
their paths itself:

| Type | Path it redirects to | Why the polymorphic helper is missing |
|---|---|---|
| `Person` | `/people/:noid` | no resourceful route — the endpoints are NOID-keyed one by one |
| `Blob` | `/files/:noid` | the route is `resources :files`, so the helper is `file_url`, not `blob_url` |

A new resource type whose route name does not match its class name needs a line
there too. The polymorphic call raises `NoMethodError` on a missing helper, so
the endpoint 500s rather than 404ing.

### One rule runs through every action here

**`authorize!` runs before the 404**, falling back to the `Resource` class for an
unresolvable id, **so the `check_authorization` hook cannot turn a miss into a
500.** An admin passes the class check and then 404s; a non-admin is denied.

### The gates are not all the same

| Action | Gate | Why |
|---|---|---|
| `permissions` | `:read` on **that resource** | The envelope names the Grouper groups and the depositor's NUID, so handing it to a caller who may not read the resource **discloses the rights of something they cannot see.** Cerberus reads this to drive its own gate, and its callers hold read or edit rights either way. |
| `mods_versions` | `:read_versions` on the resolved record's class (admin and the devolved-admin tier) | The descriptor list carries audit-derived actor attribution, so it sits above the read gate. It uses the narrow verb that File versions use, not `:read, AuditEvent`, so a delegate reads the per-object list without opening `/history`. |
| `mods_version` | `:read` on the resource | Same content sensitivity as the public head `/mods` — it is the descriptive metadata itself, not the attribution. |
| `mods` | `:read` on the resolved record | Matching the typed per-record gate, **so a gated object's MODS is exactly as protected here as via `/works/:id/mods`.** |
| `reindex`, `reindex_subtree` | `:system` | Operational actions, never user ones. |

`mods_versions` returns an empty array rather than a 404 for absent MODS, a
non-Modsable type, or an unresolvable id — mirroring `/history`'s "no events"
shape. A delegate holds `:read_versions` only on the Modsable types and `Blob`,
so for any other type, or an unresolvable id, a delegate gets 403 where an
admin gets the empty array.

### A tombstone carries a policy removal note

`POST /resources/:id/tombstone` takes an optional `reason`, and the reads return
it as `tombstone_reason`. The library's removal policy requires a note that
stays in view after removal, and it fixes the wording, so Atlas accepts only the
five notes in `Resource::TOMBSTONE_REASONS` and refuses anything else with `422
invalid_reason`. Cerberus keeps its own copy of the list for the picker, but
Atlas is the authority.

- **The note carries no date.** The policy writes each note with a date, and
  `tombstoned_at` already holds it. A stored date could disagree with the stamp.
- **It is not in MODS.** The obvious home is `accessCondition
  type="suppressed"`, but the display decorator and the OAI `dc:rights` export
  both read accessCondition, so every reader would have to learn to skip it. A
  tombstone and a restore would also each need a MODS write beside the
  resource save. The note is lifecycle state, so it lives with the other
  tombstone fields.
- **It rides the envelope instead,** with `tombstoned_at` and `tombstoned_by`,
  so the preserved record keeps it. Tombstone and restore both rewrite the
  envelope. A derivative FileSet is the exception, because it has no OCFL object
  of its own.
- **Restore clears it,** and the tombstone audit event records it in
  `payload.reason`.
- **It is not indexed.** Discovery excludes tombstoned resources, so nothing
  searches on the note.

### A top-level Community cannot be tombstoned, purged or moved

Two Communities have no parent: the repository root and the People Community.
Every ancestor chain, trail and gated query hangs from one of them, so
`tombstone` and `destroy` answer `422 top_level_community` for either, and so
does a re-parent (see below). The API offers no way to remove a root, to admins
and the system principal alike; it is an operator task.

- **The refusal comes first.** It runs before `has_live_children` and
  `has_children`, so the answer cannot reveal whether a root is empty.
- **It lives in the controllers only.** `Resource#tombstone`, `Reparenter`,
  `ResourcePurger` and the persister do not check it, so an operator at the
  Rails console can still tombstone, purge or move a root.
- **It does not stop a client-side cascade.** A client that tombstones a subtree
  deepest first reaches the root last, after everything under it is tombstoned.
  Such a client must refuse a root before it starts.
- **Restore is not refused,** so a root tombstoned at the console can still come
  back through the API.

### Tombstoning runs leaf-first, restore runs root-first

Neither action cascades, so each refuses the order that would leave a readable
resource inside a tombstoned one. `tombstone` answers `422 has_live_children`
while the resource still holds a live Community, Collection or Work. `restore`
answers `422 tombstoned_parent` while the resource's parent is still
tombstoned; otherwise a Work would come back discoverable inside a tombstoned
Collection. A top-level Community has no parent, so its restore is never
refused. The reparenter refuses the matching move into a tombstoned parent with
the same code.

Creating a Work, Collection or Community under a tombstoned parent answers the
same `422 tombstoned_parent`. The check is in `ParentScopedCreate`, after the
edit-rights check, so a caller without rights gets 403 and learns nothing about
the parent. Together these rules keep one invariant: everything beneath a
tombstoned container is itself tombstoned.

The rule does not reach a file. `POST /file_sets` and `POST /files` still accept
a tombstoned Work.

#### A restore comes back no wider than its parent

A restore narrows the resource's read groups to their intersection with its
parent's, then clears the tombstone. A narrowing cascade from Cerberus cannot
read a tombstoned resource, so it skips one. Without the clamp, a Work
tombstoned while its Collection was public would come back public inside a
Collection narrowed since.

- **The parent is enough to check.** A live parent already fits inside its own
  parent, because `PermissionsWriteGuard` refuses any write that would make it
  wider, and a restore needs a live parent.
- **The restore's audit event records a narrowing,** as `read_before` and
  `read_after`. An empty `read_after` means no group in common was left, so
  only the Work's editors and the operator tiers can read it, which is what the
  cascade gives in the same case.
- **Only a resource with its own ACL is clamped.** A FileSet reads through its
  Work, so its restore changes no ACL. A Work's derivative tiers need no write,
  because each one is clamped to the Work's read groups when it resolves.
- **Edit groups are untouched,** as in the containment check.

### A FileSet can be tombstoned, and nothing else below a Work can

`tombstone` and `restore` answer for a FileSet as well as the three typed
containers; every other generic write still 404s on one. **This is how a
caption, or any other attached file, is tombstoned reversibly.** `DELETE
/files/:id` is the only other removal, and it takes every retained revision
with it.

- **The FileSet, not the Blob, is the unit.** Its Blobs ride along, as a Work's
  FileSets do, because `live_children?` counts only containers and Works.
- **The asset listings drop a tombstoned FileSet.** `GET /works/:id/assets` and
  `/file_sets` skip it, and `PageAssetsQuery` skips a tombstoned nested FileSet,
  so no consumer needs its own filter. The Blob's bytes are withheld too; see
  [A tombstone withholds the resource below the operator tiers](#a-tombstone-withholds-the-resource-below-the-operator-tiers).
- **`GET /works/:id/tombstoned_assets` lists what the others drop.** Without it,
  Restore needs an id that nothing can look up once the tombstoning page is
  gone. It is a separate route, not a flag on `/assets`, so tombstoned files sit
  behind the tier that tombstones them rather than one parameter away from every
  public download listing and its response cache. It covers the Work's direct
  FileSets only, as `/assets` does: a tombstoned nested FileSet is not listed.
- **Every asset entry carries `file_set`**, the NOID of the FileSet it is listed
  under, because tombstone and restore take a FileSet id and an asset entry
  otherwise names only the Blob or Delegate.
- **The audit row hangs off the parent Work**, with `change_type: 'file'` and the
  FileSet's NOID in the payload, because `AuditEvent` admits no FileSet.
- **Only the devolved-admin tier and admins may do it.** A standard user's edit
  rights on the Work do not extend to it. See
  [`authorization.md`](authorization.md).

### A tombstone withholds the resource below the operator tiers

A tombstone means "remove this from view", and the reason for the removal is
not known in general: the problem can lie in the file, the description or the
title. So below the operator tiers, a tombstone withholds everything about the
resource that a search engine could keep indexing. The admin and delegated-admin
tiers keep it all, because they review a removal before they restore it.

The rule covers every resource type: a Community, a Collection, a Work, and a
Work's FileSets, Blobs and Delegates. A tombstone does not cascade, so a leaf
reads its ancestors. `tombstone_source` returns the first tombstoned resource
among the leaf and its chain up to its read authority, or nil. A container or a
Work answers for itself.

| Route | Below the operator tiers | Admins and delegated admins |
|---|---|---|
| `GET /works/:id`, `/collections/:id`, `/communities/:id` and their `/children` | 410 with a stub: id, title, permanent URL and the tombstone fields | 410 with the full record |
| `GET /files/:id`, `/file_sets/:id`, `/delegates/:id` | `410 tombstoned` | 410 with the full record |
| The bytes: `/files/:id/content`, `/files/:id/versions/:version_id/content` | `410 tombstoned` | Served |
| The file lists: `/works/:id/assets`, `/file_sets`, `/file_revisions` | `410 tombstoned` | Served |
| The metadata: MODS, METS, Darwin Core, their versions, associations, linked members, the ACL envelope | `410 tombstoned` | Served |
| `POST /resources/find_many` | The row, flagged, with its thumbnail nulled | The row, flagged |
| `GET /files/:id/ancestry` | 200, with `file_set_tombstoned` and `work_tombstoned` | The same |

- **The stub keeps the title** because the removal page names what was removed.
  A 410 is not indexed, so the title on it does not keep the resource findable.
  The stub drops the description, the thumbnail and preview URLs and the
  tombstoning operator's NUID.
- **A thumbnail URL is withheld wherever it appears.** The image server answers
  it without asking Atlas, so a URL handed out stays live.
- **The ancestry read stays open.** It carries NOIDs and tombstone flags only,
  and it is how a client learns which ancestor withholds a file.
- **The 410 names the tombstoned resource.** `tombstoned_resource_type` tells a
  removed file (`FileSet`) from a suppressed Work (`Work`), which a client shows
  differently.
- **The gate is `:read_tombstoned`,** which the operator tiers hold on every
  resource type. It runs after the read check, so a caller who may not read the
  resource gets 403 and learns nothing about the tombstone.
- **The gate runs before the response cache.** The cached 410 is the operators'
  full record, so a withheld caller is answered before the cache is read, and the
  stub is never stored.
- **Lists already drop a tombstoned resource.** Search, the collection digests,
  `descendant_works` and Set contents filter on `tombstoned_bsi`, and OAI-PMH
  answers a deleted record with its header only.
- **Atlas cannot gate the IIIF image server.** Cantaloupe reads the JP2s without
  asking Atlas, so a IIIF URL that a client already holds still works. Atlas
  stops handing the URLs out, through the file lists, the Delegate record and
  the thumbnails.
- **`spec/requests/access_matrix_spec.rb` checks the rule on every route.** See
  [`testing.md`](testing.md#the-access-matrices).

#### A tombstone refuses writes below the operator tiers

A write to a tombstoned resource, or to a leaf of a tombstoned Work, answers
`410 tombstoned` below the operator tiers. The admin and the delegated admin pass,
because the repair flow is tombstone, repair, restore: requiring a restore first
would put an unsafe item back in view while it is fixed. Each write calls
`refuse_tombstoned!` after its own `authorize!` and nil check, so a caller who may
not write learns nothing about the tombstone. A leaf create checks the Work it
lands in.

The tombstone grants nothing. An operator still needs whatever the live
resource's gate asks for, such as the edit grant `PUT /resources/:id/mods`
needs.

Four writes leave the gate out:

- `POST /resources/:id/restore`, whose target is tombstoned by definition.
- `DELETE /resources/:id`, which is admin-only.
- `POST /resources/:id/reindex` and `/reindex_subtree`, so a withheld resource's
  Solr document can still be rebuilt.

A container create into a tombstoned parent is refused separately, with 422, for
every caller (`ParentScopedCreate`). `spec/requests/write_matrix_spec.rb` checks
the rule on every write route.

### `/mods` renders the typed view

`TYPED_MODS_VIEWS` maps a resolved class to its ivar and template, so the
polymorphic route renders **the same per-type view the typed routes use.** Output
and format negotiation are byte-identical, and **there is no second MODS
representation to drift.**

Only the three container and object types carry a MODS view. A FileSet, Blob or
Person resolves fine but has no MODS projection, so it falls through to a 404.

### `find_many` filters per row

The class check answers "may this principal use the resolver at all". **The read
gate is applied per row, because the ids are arbitrary caller input — without the
filter this is a batch bypass of the single-resource read gate.**

The endpoint already contracts to drop ids it cannot resolve, so a withheld row
reads the same as an absent one. Tombstoned resources are kept but flagged, so
callers can render a placeholder. Below the operator tiers the placeholder has
no thumbnail.

**`MODSPreloader` is not optional.** The digest renders a title and a thumbnail
per row, each its own read. Batching both is what stops the endpoint trading N
round-trips for N×3 queries and **merely moving the fan-out from HTTP to
Postgres.**

It resolves NOIDs only; raw Valkyrie ids are not a supported input.

### `children` answers for a tombstoned container

`GET /collections/:id/children` and `/communities/:id/children` answer 410 for
a tombstoned container, with the stub below the operator tiers. That is the right answer for a consumer, and it leaves
an operator unable to walk a tombstoned subtree. **`GET /resources/:id/children`
is the operator's read,** in `ResourceChildrenController`. It lists every child
of a Community or Collection, live or tombstoned, whatever the container's own
state.

- **It is a separate route, not a role check on the typed one.** The typed route
  then answers the same for every caller, an admin browsing Cerberus included.
- **The gate is the `/solr` gate,** `:read_index` then `:read`, through
  `IndexReadGate`. Inspection clients sign in with a read-only token, and
  `:read_index` is already on its allowlist. Each child also passes the read gate
  per row, as the typed route's children do.
- **Rows have the `find_many` digest shape,** so each one carries `klass` and
  `tombstoned` without a second read.

### `descendant_works`

Every Work beneath a container at any depth: flattened, permission-gated,
Solr-projected, paginated.

It is the structural counterpart to `/compilations/:id/contents` — same digest
shape and query engine, but the container set is the resource's own subtree
instead of a Set recipe. Only structural membership counts unless
`?include_linked=true`.

**Gating is per-Work inside the query**, through the shared read gate
([`search.md`](search.md)), so a restricted Work never leaks through the subtree
and one the caller can edit is never hidden. Ids are
projected from Solr at every step, **so even a 10,000-deep collection never
materializes its children.**

### `reindex` is side-effect-free

Solr only: no Postgres write, no optimistic-lock bump, no lifecycle transition,
no audit row, no minting.

**That is the point.** When an indexer ships or changes, a resource finalized
before it carries a stale projection and must be re-indexed **without abusing a
lifecycle transition** like `POST /works/:id/complete`. Idempotent.

`reindex_subtree`'s gather is a **deliberate superset of the re-parent cascade**:
descendant containers *plus* the Works beneath them. A reindex refreshes any
projection, including ones that live on Works, **which the container-only
reparent cascade never touches.**

It stays synchronous, matching Atlas's no-background-jobs posture. For a
pathologically large subtree the caller roots lower or drives it in chunks.

## Re-parenting is two-sided

`PATCH /<type>/:id/parent` takes `{ parent_id }`.

**`authorize! :reparent` runs on both the moved node and the destination.**
Moving structure is an admin-adjacent operation: `:admin` holds it through
`manage :all`, and the devolved-admin tier holds it explicitly. **Edit rights
does not imply it for anyone else** — see [`authorization.md`](authorization.md).

The structural validation — type, cycle, tombstone — lives in `Reparenter` and
surfaces as a 422.

**A given-but-unresolvable parent is a 422, not a 404**, because the parent is
request input rather than the addressed resource.

**Nothing moves to or from the top of the tree.** A nil `parent_id` is `422
parent_required` for every type. Moving a top-level Community anywhere is `422
top_level_community`, because it would demote the root. Moving any Community to
the top would mint a second root that nothing protects. `Reparenter` itself
still accepts a nil destination for a Community, so a console operator can make
that move; the refusal lives in `Reparentable`, for the reason given under
[the top-level Community](#a-top-level-community-cannot-be-tombstoned-purged-or-moved).
