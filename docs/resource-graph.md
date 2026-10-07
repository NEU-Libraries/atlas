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
| `derivative_permissions` | No | Derived and advisory — Cerberus and the IIIF layer enforce it. |
| `tombstoned_at`, `tombstoned_by`, `tombstone_reason` | **Yes**, schema v7, as one `tombstone` block | A withdrawal is a person's decision that nothing else records. A rebuild that lost it would bring withdrawn objects back into view, and drop the removal note the withdrawal policy requires. |

`full_text` and `derivative_permissions` are omitted for the same reason the
fungible thumbnail derivatives are: **they can be made again.**

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
| v6 → v7 | Added `tombstone` — `at`, `by` and `reason` while withdrawn, null while live |

**`position` is additive even though the Work-level METS structMap is the
canonical record of order.** It keeps each FileSet's own OCFL object
self-describing in isolation.

**`associations` has to survive on disk** because each edge is a human judgement
about two objects that nothing else in the repository records and no job can
derive again.

**`a_linked_member_of` is deliberately absent.** A linked membership is a
discovery convenience a Set recipe can express again, not an assertion that
exists nowhere else.

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

### A withdrawal carries a policy removal note

`POST /resources/:id/tombstone` takes an optional `reason`, and the reads return
it as `tombstone_reason`. The library's withdrawal policy requires a note that
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

### A top-level Community cannot be withdrawn, purged or moved

Two Communities have no parent: the repository root and the People Community.
Every ancestor chain, trail and gated query hangs from one of them, so
`tombstone` and `destroy` answer `422 top_level_community` for either, and so
does a re-parent (see below). The API offers no way to remove a root, to admins
and the system principal alike; it is an operator task.

- **The refusal comes first.** It runs before `has_live_children` and
  `has_children`, so the answer cannot reveal whether a root is empty.
- **It lives in the controllers only.** `Resource#tombstone`, `Reparenter`,
  `ResourcePurger` and the persister do not check it, so an operator at the
  Rails console can still withdraw, purge or move a root.
- **It does not stop a client-side cascade.** A client that withdraws a subtree
  deepest first reaches the root last, after everything under it is withdrawn.
  Such a client must refuse a root before it starts.
- **Restore is not refused,** so a root withdrawn at the console can still come
  back through the API.

### Withdrawal runs leaf-first, restore runs root-first

Neither action cascades, so each refuses the order that would leave a readable
resource inside a withdrawn one. `tombstone` answers `422 has_live_children`
while the resource still holds a live Community, Collection or Work. `restore`
answers `422 tombstoned_parent` while the resource's parent is still
tombstoned; otherwise a Work would come back discoverable inside a withdrawn
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

### A FileSet can be tombstoned, and nothing else below a Work can

`tombstone` and `restore` answer for a FileSet as well as the three typed
containers; every other generic write still 404s on one. **This is how a
caption, or any other attached file, is withdrawn reversibly.** `DELETE
/files/:id` is the only other removal, and it takes every retained revision
with it.

- **The FileSet, not the Blob, is the unit.** Its Blobs ride along, as a Work's
  FileSets do, because `live_children?` counts only containers and Works.
- **The asset listings drop a tombstoned FileSet.** `GET /works/:id/assets` and
  `/file_sets` skip it, and `PageAssetsQuery` skips a tombstoned nested FileSet,
  so no consumer needs its own filter. The Blob's own reads still answer, as a
  tombstoned Work's Blobs do.
- **`GET /works/:id/withdrawn_assets` lists what the others drop.** Without it,
  Restore needs an id that nothing can look up once the withdrawing page is
  gone. It is a separate route, not a flag on `/assets`, so withdrawn files sit
  behind the tier that withdraws them rather than one parameter away from every
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
callers can render a placeholder.

**`MODSPreloader` is not optional.** The digest renders a title and a thumbnail
per row, each its own read. Batching both is what stops the endpoint trading N
round-trips for N×3 queries and **merely moving the fan-out from HTTP to
Postgres.**

It resolves NOIDs only; raw Valkyrie ids are not a supported input.

### `children` answers for a withdrawn container

`GET /collections/:id/children` and `/communities/:id/children` answer 410 for
a tombstoned container. That is the right answer for a consumer, and it leaves
an operator unable to walk a withdrawn subtree. **`GET /resources/:id/children`
is the operator's read,** in `ResourceChildrenController`. It lists every child
of a Community or Collection, live or withdrawn, whatever the container's own
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
[the top-level Community](#a-top-level-community-cannot-be-withdrawn-purged-or-moved).
