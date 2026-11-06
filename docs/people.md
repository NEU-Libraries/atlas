# People

A Person is a curatorial identity, not preserved content — and that distinction
drives every decision here.

Source files:

- `app/services/person_creator.rb`
- `app/services/personal_root_creator.rb`
- `app/queries/find_people_by_nuids.rb`
- `app/queries/search_people.rb`
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

## A person may edit their own profile

A signed-in person may change their own Person's `display_name`, `bio` and
`orcid` through `PATCH /people/:id`. Nothing else about a Person is theirs to
change: its NUID is immutable, and its affiliations stay curatorial
(`:system` and admin only).

The rule is `:update_profile`, granted to the `standard`, `loader` and
`privileged` roles for the Person whose NUID matches the authenticated user's.
Three points keep it narrow:

- **It is a verb of its own, not a rule on `:update`.** CanCanCan answers a
  class-level check true when any rule for that verb exists, block or not. The
  affiliation actions check `authorize! :update, Person` before any lookup, so a
  self rule on `:update` would let every signed-in user change anyone's
  affiliations.
- **It keys on the authenticated subject.** Acting-as never changes the NUID
  compared: the operator stays `@current_user`, and the `obo` target only
  attributes the audit row.
- **A guest holds no write rules**, so a guest-role user cannot edit a Person
  even when the NUIDs match.

Admins hold the verb through `manage :all`, and `:system` holds it beside
`create` and `update`. The update authorizes after the lookup, because the rule
needs the Person; a missing Person answers 404.

**The display name is no longer librarian-only.** It is still never re-synced
from SSO, so a person's own correction survives every login.

The update validates every caller's write, librarian or self, before anything
is saved, and answers 422 with a code (see
[`error-contract.md`](error-contract.md)):

- `display_name` must not be blank (`blank_display_name`).
- `bio` is at most 4,000 characters (`invalid_bio`). A blank `bio` clears it.
- `orcid` must be a bare ORCID iD, `0000-0002-1825-0097`, whose last character
  passes ORCID's ISO 7064 MOD 11-2 check (`invalid_orcid`). The `https://orcid.org/`
  form is refused. A blank `orcid` clears it.

`POST /people` does not validate these fields. Its caller is `:system` after
SSO, and a refused create there would fail a sign-in.

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

## Searching People

`GET /people?q=` is the admin People-index typeahead. A fragment matches a
`display_name` by case-insensitive infix, a NUID by prefix, and the email of any
account holding that NUID by case-insensitive infix. People are not in Solr, so
`SearchPeople` matches in Postgres, reading `metadata->'display_name'->>0`
because of the array-wrapping above.

**The match is counted and paged in SQL**, through a `LazyPagination::SqlPage`
source, so the `pagination` block counts matches rather than the registry. The
matches are ordered by `display_name`, which is what an admin reads.

It is admin-only. Matching on NUID and email would let any other caller
enumerate both; see [`authorization.md`](authorization.md).

## The user directory shows the curated name

The SSO feed rewrites `users.name` on every login, so a librarian's correction
lives only on the Person. `GET /users` therefore left-joins each account to the
Person for its NUID and:

- **matches the fragment against both names**, so a renamed person is found by
  the name a librarian gave them, and still by the SSO name;
- **returns the Person's name as `display_name`**, or `null` when the NUID has no
  Person or its name is blank;
- **orders by the name an entry shows**: `display_name` when set, else `name`.

`display_name` discloses nothing new: a Person is public, and `/people/:id`
already serves the name. The join uses the same containment shape as
`FindPeopleByNuids`, so the `jsonb_path_ops` index serves it, and the name
expression comes from `SearchPeople.display_name_sql`, so the two searches match
one way.
