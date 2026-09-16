# Authorization

How Atlas decides whether a principal may read or write a resource, once
`require_auth` has established who they are. Authentication — which credential
proved the identity — is [`authentication.md`](authentication.md).

Source files:

- `app/models/ability.rb` — the cancancan matrix every action consults
- `app/models/concerns/permissions.rb` — the ACL envelope on a Valkyrie resource
- `app/models/compilation/acl.rb` — the ActiveRecord mirror of that envelope
- `app/services/permissions_write_guard.rb` — vets an incoming ACL edit
- `app/models/concerns/tier_visibility.rb` — per-asset download visibility

## Atlas is the boundary; Cerberus is the experience

Both apps have an `Ability`. Cerberus's decides whether a button renders. Atlas's
decides whether the request succeeds, and it is the system of record.

Divergence between them is recoverable rather than a privilege escalation. If
Atlas denies what Cerberus allowed, the user sees an actionable element that 403s
when clicked. If Cerberus denies what Atlas allows, a direct API caller still
reaches Atlas, and Atlas's answer is the effective one. So a rule that must hold
belongs here, and a rule that only tidies a screen belongs there.

`ApplicationController`'s `check_authorization` hook raises
`CanCan::AuthorizationNotPerformed` when an action forgets to call `authorize!`.
A new write action therefore cannot silently skip the gate.

## Class checks and instance checks

The distinction decides whether a rule can run at all, so it is a correctness
matter rather than a style one.

| Check | When | Examples |
|---|---|---|
| Class — `authorize! :create, Work` | The decision does not depend on resource state | `:create`, admin-only `:destroy`, verbs on models with no per-row ACL (`User`, `AuditEvent`) |
| Instance — `authorize! :update, @work` | The decision reads the resource's own ACL | `:read`, `:update`, `:tombstone`, `:create_child` |

**A block-form rule cannot evaluate against a class.** cancancan lets
`authorize! :read, Work` through, because there is no instance for the block to
inspect. On `:read` that is the difference between a gate and no gate at all, so
a controller resolves the record first and authorizes the instance:

```ruby
authorize! :read, work || Work
```

The `|| Work` fallback keeps an unresolvable id on the 404 path instead of
tripping the `check_authorization` hook. A list endpoint cannot do this per row,
so it either filters the rows or is restricted to `:index_all`, which only
`:admin` holds. `spec/models/ability_spec.rb` fails if the `:read` rule ever
loses its condition.

## Creating takes two checks

A create is authorized twice, because it asks two different questions:

1. `:create` on the **class** — may this principal author this type at all? This
   is a role question. `:system` may author containers but never a `Work`.
2. `:create_child` on the resolved **parent** — may they write into this
   container? This is an ACL question.

The child has no state to inspect yet, but the container it lands in does.
Writing into a container you do not control is the same class of structural
mutation as `:reparent`. `ParentScopedCreate` is the controller half.

A parentless Community sits at the top of the tree and has no container to
consult, so the class check is the whole gate there.

## Verbs that travel with `:update`

`UPDATE_ALIASES` aliases the machine-set derived-metadata verbs to `:update`:
`update_thumbnails`, `update_image_derivatives`, `update_derivative_permissions`,
`update_iiif_service`, `update_full_text`, `complete`, `mark_incomplete` and
`clear_incomplete`. They all mutate resource state, and a caller who can
`:update` can do all of them, which keeps the group-ACL rules to one `:update`
declaration per class.

`mark_incomplete` and `clear_incomplete` sit here rather than on the operator
tier because the same Cerberus job that deposits a Work is the one that reports
its pipeline gave up, and that job already holds `:update`.

**Four verbs are deliberately not aliased**, and non-admin humans get none of
them through edit rights:

| Verb | Why it is not an edit-rights verb |
|---|---|
| `:reparent` | Structural mutation of the content graph |
| `:link_member` | Same, with one narrow `:system` exception below |
| `:restore` | Reversing a withdrawal is an operator action, though `:tombstone` does ride edit rights |
| `:associate` | The claim renders on **both** Works, including a target the asserter may hold no rights over |

`:associate` is the subtlest. Edit rights on the asserting Work would otherwise
let anyone hang an inbound link off a well-known Work whose owner never asked for
it.

## The role tiers

`apply_role_abilities` switches on `User#role`.

### `:system`

A backend-to-backend credential held only by Cerberus, never a human. Tightly
enumerated, and everything outside the list is denied — it cannot author Works,
mutate any resource, or tombstone, restore or destroy anything.

It holds `:provision` and `:mint_token` on `User` for the SSO path,
`:read_directory`, `:maintain` on `:maintenance`, and `:reindex` on `Resource`.
Reindex is a side-effect-free Solr re-projection: no Postgres write, no lifecycle
transition, no audit row.

`:system` also holds `%i[create update]` on `Person`, because name authority and
affiliations are curatorial rather than self-service.

**`:system` is the one principal that reads past the per-resource gate.** The
work it does on a depositor's behalf — showcase publishing, provisioning,
operational reindexes — needs to read resources it shares no group with, and it
renders the result of its own writes. Linking a Work into a featured showcase
answers with the membership list, which it could not see under the gate. The
grant is declared inside the role branch rather than in the base rule so that it
comes last and wins. Cerberus is the layer that decides what a *person* may see,
and this token never reaches one.

**The container carve-out is a pair.** `can :create, [Community, Collection]`
says which types `:system` may author; `can :create_child, [Community,
Collection]` says which containers it may write into, unconditionally, because
the seed task bootstraps a tree it has no ACL foothold in. The pair is what keeps
Works out of reach: a Work create still fails the class-level `:create, Work`
check even though its parent Collection passes `:create_child`.

**Showcase publishing** is scoped on both sides, so a Cerberus bug cannot become
worse than "linked the wrong Work into a showcase":

```ruby
can :link_member, Collection, &:featured
can :link_member, Work do |work|
  @on_behalf_of.present? && work.depositor == @on_behalf_of
end
```

`:system` still cannot mutate Collection metadata, tombstone, or touch a
non-featured Collection, and can only link a Work owned by the asserted
`on_behalf_of` target rather than an arbitrary or private one.

### `:guest`

`GET /user` only — a guest may look up the principal it is already acting as. It
gets no resource-modifying ability.

**Not `:read_directory`.** The user directory answers name-and-NUID for any
fragment, and NEU IT Security treats NUID disclosure as an enumeration risk, so
it takes a real credential.

### `:standard`, `:loader`, `:privileged`

All three authenticate as standard humans at Atlas's wire, and Atlas's endpoints
do not distinguish them. Their role-derived differences — the batch-ingest
surface, the proxy-upload control — live in Cerberus's `Ability`. Split the case
out only when an Atlas-side rule actually keys on one of them.

They hold `:read` and `:read_directory` on `User`, `:preview` on `Resource`, and
`:create` on `Work`, `Community`, `Collection` and `Compilation`. Any signed-in
human may curate their own Sets; guests may not.

**`FileSet` and `Blob` writes are not group-ACL-gated at the wire.** They hang
off Works, and Atlas cannot cheaply trace a FileSet back to its Work. The role
gate at Work creation is the entry barrier: once you can author a Work, you can
attach FileSets and Blobs to it. `:destroy` is absent on both — admin only.

### `:admin`

`can :manage, :all`. Minimal membership by design. It bypasses both role
enumeration and group ACLs.

## The group ACL axis

`apply_group_abilities` grants `%i[update tombstone]` on `Work`, `Collection` and
`Community` to anyone with an edit grant, and `:create_child` on `Collection` and
`Community` on the same test.

`:create_child`'s subject is always the **container**, never the child. A Work is
never a container of Works or Collections, so only those two types can be the
subject.

An edit grant is `edit_grants?`: a group ACL match **or** ownership.

```ruby
group_acl_grants?(resource, user) ||
  (resource.depositor.present? && resource.depositor == user.nuid)
```

**Ownership has to count separately, because it is not in the ACL.** A personal
root and everything beneath it carries `edit: [repository:staff]` with the owner
recorded only as `depositor`. A non-staff owner would otherwise be locked out of
their own workspace. So a depositor may edit, withdraw and deposit into their own
resource independent of Grouper membership. `:restore` is deliberately not one of
those verbs.

`group_acl_grants?` is the ACL half alone: the caller's NUID in `edit_users`, or
any of the caller's groups intersecting `edit_groups`. Its shape mirrors the
Cerberus-side check, and both layers consult the same envelope.

## Reading a resource: `read_authority`

A resource is readable when its own access controls say so — public, a read-group
match, or any edit grant, since edit implies read.

**Leaves do not answer for themselves.** `FileSet`, `Blob` and `Delegate`
delegate to `read_authority`, which walks up to the Work or container above them.
Every creator copies the parent's ACL down at creation, but nothing rewrites that
copy afterwards, and Cerberus's narrowing cascade walks Works and containers
only. A leaf privatised after its FileSets existed still carries
`read: ['public']` on them. Reading a leaf's own copy would serve the bytes of a
Work that has since been closed, which is the failure this gate exists to stop.

**A nil authority denies.** That covers an unresolvable resource and an
unattached leaf with nobody to answer for it, and deny is the safe answer for
both.

**Embargo is not consulted here.** Cerberus does not gate on embargo state at its
discovery layer and neither does `WorkDigestQuery`, so gating here would put the
resolutions out of step. Embargo withholds downloads further up, in Cerberus.

## Compilations carry their own visibility

A `Compilation` is an ActiveRecord row, not a `Resource`, so it does not ride the
resource gate. `compilation_readable?` answers public, owned, a read-group match,
or any edit grant.

`:read` is granted to `:guest` too, because `public?` is what anonymous traffic
rides on. On the write side there is deliberately **no staff default**: owner plus
explicit grants, with `:admin` covering the rest through the wildcard.

## The devolved-admin tier

`apply_admin_delegate_abilities` keys on `User#admin_delegate?`, which requires
the `:privileged` role **and** `Permissions::ADMIN_GROUP` jointly — neither alone
is sufficient. `:admin` already passes everything below through the wildcard, so
this method only covers the narrower delegate case.

Each grant is a named carve-out beneath the wildcard, not a promotion:

- **`:reparent` on `Work`, `Collection` and `Community`.** All three, because this
  matrix never distinguished resource types for `:reparent`, so the grant covers
  everything `Reparentable` exposes rather than whatever subset a caller's screen
  happens to show. Unconditional and system-wide, not scoped to the delegate's own
  `edit_groups`.
- **`:restore` on the same three.** Beside `:reparent` for the same reason.
- **`:associate` on `Work`.** See the alias table above.
- **`:create` on `AuditEvent`.** Unblocks Cerberus's impersonation session-start
  write; view-as and acting-as both call it before establishing a session.
  Unscoped rather than conditioned on `mode`, because `POST /audit_events` has
  exactly one caller system-wide, and Cerberus's own admin-only acting-as gate is
  what prevents a delegate reaching acting-as.
- **`:read_versions` on `Blob`.** A narrower verb than `:read, AuditEvent`, so the
  grant cannot be mistaken for opening the audit-history surface.

## The ACL envelope

`Permissions` defines the ACL on a Valkyrie resource, and
`Preservable` projects its `permissions` hash to disk, which is why the envelope
shape is a preservation concern and not only an access one.

`AUDITED_ACL_KEYS` is `%i[read edit edit_users embargo]` — the before/after
payload of a `permissions` audit event. **Embargo belongs in the diff** because it
is a rights decision a human makes and revises, and nothing else records who
moved it. The provenance slots stay out, being write-once rather than part of a
rights diff.

### Provenance

| Field | Meaning |
|---|---|
| `depositor` | The intellectual owner. May point at the seeded `:anonymous` user for batch loads. |
| `proxy_uploader` | The hands-on-keyboard actor for the most recent ownership-affecting write. Equals `depositor` on self-deposit; differs on a librarian-on-behalf deposit. |

Both are single NUID strings, denormalized so they read as O(1) Solr fields
(`depositor_ssi`, `proxy_uploader_ssi`). The append-only history lives in
`AuditEvent`.

**Both slots are write-once, and the setter enforces that by omission.** The
metadata PATCH path passes only ACL keys through `permissions=`, so a missing
`:depositor` key must not nil an existing stamp. Creators copying
`parent.permissions` always include both keys, so they still write through, and
the copy-then-stamp invariant holds.

### The staff auto-prepend

`permissions=` prepends `STAFF_EDIT_GROUP` to `edit_groups` when the incoming
list omits it, and `delete_edit_group` refuses to remove it. Repository staff
therefore always hold edit rights on a resource.

### Why `presence` on the embargo getter

`permissions` reads `embargo_release_date.presence&.to_s`. The setter normalizes a
blank date to `''`, but a resource never put through the setter — a root Community
— still holds `nil`. Without `presence`, the audited slice would read that
`nil → ''` step as a change and emit a `permissions` event in which nothing moved.

### Two envelopes, deliberately mirrored

`Compilation::ACL` mirrors the store-agnostic slice of `Permissions` rather than
including it. **Mirror, do not extract:** `Permissions` is welded to Valkyrie
attributes and sits on the preservation-envelope path, and refactoring it for one
ActiveRecord consumer is risk without payoff. Change one, check the other.

It is named `ACL` and not `Compilation::Permissions` because a nested
`Permissions` constant would shadow the top-level concern inside the namespace,
turning every `::Permissions` cross-reference into a constant-lookup trap.

It omits three things on purpose:

- No embargo and no `proxy_uploader` — Compilations carry neither.
- No staff auto-prepend, and no delete guard for it. A *personal* Set should not
  be staff-editable by default.
- `depositor` is write-once at create, stamped by the controller from the
  authenticated NUID, and `permissions=` never touches it.

`AUDITED_KEYS` is local rather than borrowed from `AUDITED_ACL_KEYS`, because that
constant also carries `:embargo`, and slicing a key that is never present is a
claim this mirror cannot honour.

## Editing an ACL: `PermissionsWriteGuard`

The guard vets an incoming envelope before it reaches `permissions=` and returns
what should actually be written. Both rules need context the setter does not
have: the structural parent, and the acting user.

### Rule 1 — containment

A resource may be no more visible than its container. The creators establish the
invariant by copying `parent.permissions`; the guard keeps it true across edits.

This matters because **gated discovery filters on the resource's own read groups
with no ancestry term**. A public Work inside a restricted Collection is
discoverable and downloadable by anyone while its parent 403s.

A violation is refused with a 422 rather than silently clamped, because the caller
asked for an audience it may not have. A root Community has no parent and is
exempt.

The check runs against the payload **as submitted** — the caller's stated intent —
rather than the post-merge-back value, so a pre-existing violation preserved by
rule 2 cannot fail an otherwise legitimate write.

### Rule 2 — grant removal

A group grant may only be removed by a member of that group. `:admin` and the
devolved-admin tier are exempt; a nil actor is **not**, because it has no group
membership to appeal to.

Preserved grants are merged back rather than 403'd, mirroring the
`STAFF_EDIT_GROUP` treatment. The payload is a full-replacement list, so
"omitted because the caller's UI made the row read-only" and "deliberately
removed" are indistinguishable on the wire, and rejecting would break a
well-behaved client that renders those rows without a remove control. Merge-back
is also audit-clean: `Auditable` compares post-setter ACLs, so a preserved grant
writes no spurious row.

`public` is always removable. It is a visibility token rather than a Grouper
group, so nobody is a member of it and rule 2 would make it permanently
unremovable — which would stop a depositor making their own resource private.

`edit_users` is absent from `GROUP_KEYS`: rule 2 is about group membership and
says nothing about individual grants.

Adding grants is unconstrained by rule 2, which only bounds the destructive
direction, but still bounded by rule 1.

## Per-asset download visibility: `TierVisibility`

Departments reserve the higher-fidelity renditions — the original above all, and
non-image renditions second — to Grouper groups, while smaller access copies stay
public. Each download rendition has its own permissions.

The policy is a sparse `{ tier => [read groups] }` map, JSON-encoded on
`Work#derivative_permissions`. The tier vocabulary reuses the resource read-group
tokens (`public`, Grouper group names, `[]` for private) so the same groups apply
unchanged.

**The gate is advisory, not an Atlas-enforced byte boundary.** Image Delegates
hold only a IIIF `uri` and Atlas never proxies the pixels, so Cerberus and the
IIIF auth layer enforce. For Blobs the enforcing point is Cerberus's
`DownloadsController` `:read` check on the stream. Atlas's read path
(`GET /works/:id/assets`, `/file_sets`) surfaces `permission` and `gated` per
asset so those layers can act.

### The image ladder cascades

`IMAGE_LADDER` is `%i[small medium large service master]`, ordered most-visible to
least, with `master` — the original image binary — as the floor.

Visibility must narrow as resolution grows (`master ⊆ service ⊆ large ⊆ medium ⊆
small ⊆ the Work`), so an absent tier inherits the next lower-resolution tier, and
`small` falls back to the Work's own `read_groups`. **This makes a sparse policy
monotonic by construction**: gating only `large` also gates `service` and
`master`, which closes the full-resolution leak.

Thumbnail and preview chrome is deliberately outside `TIER_FOR_ROLE`. It is the
open display pipe, public by construction, and never gated.

### Non-image media gate independently

`INDEPENDENT_MEDIA` is `%i[audio video pdf]`. There is no meaningful resolution
ordering across a PDF, an audio file and a video, so each is validated only
against the Work (`tier ⊆ resource`) and an absent key inherits the Work directly
with no cascade.

`media_tier` classifies a held Blob from its detected MIME type: an image original
is `master`, `application/pdf` is `pdf`, and audio and video take their media
type. PDF is keyed on the full MIME string rather than a media type, so it is
handled before the lookup. Anything else — text, office documents, archives,
metadata — has no tier and rides the Work's own read gate.

### The clamp

`derivative_gate_for` intersects the resolved tier gate with the Work's
**current** `read_groups`, so a later narrowing can never leave a stale tier
resolving broader than its Work.

The audience predicates treat `public` as the universal set. Group-name subset is
conservative-correct: if `inner ⊆ outer` as sets then `audience(inner) ⊆
audience(outer)`, whatever the unknown memberships are.

`derivative_permissions_map` degrades to `{}` on malformed JSON rather than
raising, because it sits on the read path and only the updater ever writes the
column.
