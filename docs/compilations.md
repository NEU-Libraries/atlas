# Compilations (Sets)

A personal, curated, recipe-based grouping of Works and Collections — "Sets" in
the DRS interface.

Source files:

- `app/models/compilation.rb`
- `app/models/compilation/acl.rb`
- `app/controllers/compilations_controller.rb`
- `app/controllers/concerns/compilation_memberships.rb`
- `app/queries/compilation_contents_query.rb`

The ACL mirror is covered in [`authorization.md`](authorization.md). Publishing a
Set to harvesters is [`oai.md`](oai.md).

## Nothing is materialized

The recipe is three NOID lists:

| Line | Meaning |
|---|---|
| Include-collection | Transitive — everything beneath it |
| Include-work | One Work individually |
| Exclude-work | A Work set aside |

`CompilationContentsQuery` resolves those against Solr at read time. **There is
no membership table of resolved Works**, so a Collection gaining a Work changes
every Set that includes it, with no write anywhere.

## Deliberately ActiveRecord, not Valkyrie

A Compilation is ephemeral and non-preservation, so it has no OCFL envelope, no
MODS, and no NOID-bearing Solr doc of its own.

**The public id is still a minted NOID**, from the same `Minter` and namespace as
resource NOIDs — so there are no collisions by construction, and Cerberus's
`/sets/:id` URLs match `/works/:id` in shape.

**The bigint primary key is never exposed.** Audit rows store it internally and
no endpoint surfaces it, so every controller lookup goes through
`find_by!(noid:)`.

## The join models nest under the class

`Compilation::CollectionInclusion` and its two siblings. Both halves of the
wiring are Rails convention:

1. Association class names resolve inside the parent namespace first, so
   `:collection_inclusions` finds `Compilation::CollectionInclusion`.
2. A model nested in an ActiveRecord class gets the singular parent table name
   as a prefix.

**So the children land on the `compilation_*` tables the migration created with
no `table_name` configuration at all.**

`dependent: :delete_all` is belt-and-suspenders over the foreign key's
`ON DELETE CASCADE`. It keeps AR-initiated destroys correct even outside
Postgres.

## `PUBLISHED_LIMIT` is explicit because the default bit

**v1's `ListSets` passed no `rows` and inherited Solr's default of 10, so it
truncated silently at the eleventh published set.**

The cap here is 500 — explicit and generous. It also bounds the per-page
`setSpec` resolution, since `OAISetMembershipQuery` runs one Solr query per
published set.

The `published` scope orders by NOID **so `ListSets` and a record's `setSpec`
list agree from one page to the next.**

Publishing is admin-only, and the recipe routes start emitting audit rows once
the flag is on, because **a harvester walks a published Set and copies what it
finds into another catalogue.**

## `granted_to`: the grant-scoped listings

This backs the "Shared with me" and "Editable by me" surfaces: Sets where the
principal is a **grantee but not the owner**.

| `include_read:` | Bucket | Axes |
|---|---|---|
| `false` | Editable by me | `edit_users` contains the NUID, or `edit_groups` intersects the groups |
| `true` | Shared with me | The above, plus `read_groups` intersects the groups |

Edit grants imply read, which is why the read axis is additive rather than
alternative.

**Owned Sets are always excluded** — the interface lists those under "My Sets",
and the caller's own owner-scoped listing stays a separate query.

The axes mirror `Ability#group_acl_grants?` and `#compilation_readable?`,
evaluated in SQL here instead of Ruby. **Group membership is resolved server-side
from the authenticated principal**, the same source the `Ability` consults, so no
group list crosses the wire.

**A principal with neither a NUID nor any groups — a guest — matches no grant and
gets an empty relation**, rather than everything.

`grant_clauses` returns one `[clause, bind]` pair per applicable axis, in the
order the `OR` is assembled. Postgres array overlap (`&&`) is the membership
test.

## Membership mutations: six thin actions, one shape

```
POST   /compilations/:id/included_collections { collection_id }
DELETE /compilations/:id/included_collections/:collection_id
POST   /compilations/:id/included_works       { work_id }
DELETE /compilations/:id/included_works/:work_id
POST   /compilations/:id/exclusions           { work_id }
DELETE /compilations/:id/exclusions/:work_id
```

Each one authorizes `:update` on the Set, mutates one recipe line, and re-renders
the compilation partial. **The updated recipe is the response**, so Cerberus's
chip counts refresh from the same shape it already parses.

### Both directions are idempotent

**Adds** use `find_or_create_by` and run the join-model type validation, so a
Community or an unknown NOID is a 422 through the standard `RecordInvalid`
rescue.

**Removes** are idempotent too: deleting an absent row is a 200 no-op. That
matches the remove-linked-member temperament — **there is nothing for a client to
recover from.**

## When recipe churn is audited

| Set state | Audit rows |
|---|---|
| Unpublished | **None.** Personal curation, not rights or provenance. |
| Published | **Yes.** |

A published Set is the feed `/oai` hands to outside harvesters, so **a Work
entering or leaving it is a curatorial act with consequences off this system.**
