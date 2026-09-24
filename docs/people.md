# People

A Person is a curatorial identity, not preserved content — and that distinction
drives every decision here.

Source files:

- `app/services/person_creator.rb`
- `app/services/personal_root_creator.rb`
- `app/queries/find_people_by_nuids.rb`
- `app/controllers/people_controller.rb`
- `app/indexers/person_indexer.rb`

How a Person reaches catalog results is in
[`solr-indexing.md`](solr-indexing.md).

## `PersonCreator` is deliberately lean

Unlike `WorkCreator` and `CollectionCreator`, it does **not**:

- seed a descriptive-metadata FileSet
- write a MODS template
- write an OCFL preservation envelope
- inherit any parent permissions for the Person row itself

It saves the resource to Postgres and Solr, eagerly mints the personal-root
Collection, and emits the structural create audit row.

**The root it mints *is* a preserved Collection.** The Person is not.

## A Person is born public-readable

People are public directory entries — v1's Faculty and Staff was
world-browsable.

**A Person has no parent to inherit a public ACL from**, the way a Work does, so
the creator calls `add_read_group('public')` explicitly.

Without that, `AccessControlsIndexer` projects no `read_access_group_ssim`, and
**gated discovery drops the Person from every non-admin search.**

## One Person per NUID

That is the correlation invariant. **The uniqueness guard lives in
`PeopleController#create`**, which answers 409, so `PersonCreator` stays a pure
constructor usable by specs and internal callers.

## The personal root hangs under a singleton "People" Community

Not under the person's affiliated community. Three reasons:

1. **A Person may publish across several affiliated communities**, so there is no
   single right parent.
2. **The root must not move when affiliations change.**
3. It lets the root be minted eagerly at `Person.create`, **before any
   affiliation exists.**

It mirrors v1's per-Employee "User Root", but one root per Person rather than
v1's eight-folders-per-person sprawl.

### The singleton is found-or-created idempotently

A second caller — a concurrent create, or a backfill re-run — reuses the existing
one.

It is marked by the sentinel depositor `"system"`, which **serializes into the
on-disk preservation envelope naturally**, and flagged `system_container` so
Cerberus can exclude it from discovery.

There are only a handful of Communities, so the linear `find_all_of_model` scan
is cheap.

`ensure_system_container` is **self-healing**: a People Community minted before
the flag existed acquires it, and re-projects to Solr, on the next Person
create. An already-flagged one is untouched.

## Why the root is publicized

**The People Community has no public read grant, so a root that merely inherited
its ACL would 403 for its own owner** — and collections created under it inherit
those non-readable permissions, so the owner could not view a collection they had
just made.

Publicizing the root makes it owner-navigable and lets workspace collections
inherit a public read, keeping the hierarchy consistent: a public child under a
public root. **An owner may still privatize an individual workspace collection
later.**

The resource is re-saved and the envelope re-written, so the on-disk preservation
copy carries the grant.

`personal_root` is flagged so Cerberus can exclude it from the global catalog and
rewrite breadcrumbs around it. **A personal root is a structural container, not
content.**

## Ancestor entries carry both flags

Every entry in a resource's `ancestors` carries `system_container` and
`personal_root`, so a client can recognize the People Community and a personal
root from the chain alone. Without them, a client would need one read per
ancestor to learn the flags, and only full admins can read the People Community.

**Atlas keeps these entries in the chain.** The chain is a structural fact: the
reparent cycle guard and the `AncestryIndexer` both walk it. Whether to show a
structural entry is each client's decision.

## Provisioning is an unattributed system side effect

The root and the People Community are created **without** an `actor_nuid`, so
`CollectionCreator` and `CommunityCreator` emit no structural audit rows for
them.

**The user-facing audit is the Person create itself.**

## The MODS template gets a title

`titled_mods` sets the primary title, so the on-disk envelope is
human-recoverable. **A bare `""` title would be opaque to the bus-factor new
hire.**

Nokogiri here is the write path, which is fine. The smell is parsing MODS on a
read path — see [`mods.md`](mods.md).

## NUID lookups need their own query

`Resource.find` resolves a NOID or a Valkyrie id only, so NUID-keyed lookups —
`GET /people/:nuid`, and the authoritative `display_name` batch resolve — need
`FindPeopleByNuids`.

Each disjunct is a `metadata @>` containment predicate. **Valkyrie array-wraps
scalar attribute values in the jsonb**, so a String `nuid` lands as
`{"nuid":["..."]}` and the predicate has to match that shape.

It is scoped to the `Person` `internal_resource`, **so it can never match another
type.**

NUIDs ride as bind parameters; only the placeholder count derives from input.
Postgres-specific by construction, like the other custom queries in
[`read-performance.md`](read-performance.md).
