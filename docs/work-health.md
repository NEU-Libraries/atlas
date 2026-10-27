# Work health

How to tell whether a Work is viable, needs repair, or must be restored or
replaced. Two checks give the same three grades from different sides.

Source files:

- `bin/ocfl-health` and `lib/ocfl_health/` — the offline check, read from disk alone
- `app/services/work_health_check.rb` — the Atlas check, read from Postgres, Solr and disk
- `lib/tasks/health.rake` — `atlas:health:work`
- `app/controllers/works_controller.rb` (`#health_check`) — the same check over HTTP
- `spec/exploration/work_health_probe.rb` — the destructive probe the rubric comes from

## The three grades

The grade says what repair costs. That is the decision an operator has to make.

| Grade | Severity behind it | Meaning | Action |
|---|---|---|---|
| Green | `advisory` at most | Viable. Every consumer surface answers | None |
| Yellow | `repairable` | Broken or degraded, but nothing is lost. Postgres or disk still holds what a repair needs | Repair in place |
| Red | `fatal` | Bytes are missing, corrupt or unreadable | Restore from backup, or re-deposit |

A Work takes the worst grade among its findings.

## The offline check

```bash
bin/ocfl-health --root /path/to/r001 --root /path/to/r002 WORK_NOID
bin/ocfl-health --root /path/to/r001            # sweep every object
bin/ocfl-health --root /path/to/r001 --no-fixity --json
```

It needs Ruby and the standard library, and nothing else: no bundle, no Rails,
no database. That is the case [`preservation.md`](preservation.md) is written
for. The exit status is the worst grade: 0 green, 1 yellow, 2 red.

It validates each object against OCFL 1.1, and against the two things Atlas
adds: the inventory id is `urn:neu-drs:<noid>`, and a write stages a version in
`.tmp-vN-*` before it renames it into place. It then reads the
[envelope](resource-graph.md#the-envelope-schema) to walk a Work's graph: up
through its ancestors, and down through the FileSets that name it, their Blobs,
and the MODS XML.

**A Work does not name its FileSets; each FileSet names its Work.** So the only
way to find a Work's children on disk is to read every envelope in the pool. The
offline check builds that index once per run, without fixity, and then
re-validates the objects the Work reaches with fixity on.

**The offline check sees only what disk holds.** A direct write to Postgres does
not rewrite the envelope, so damage done there is invisible offline until the
next envelope write. The reverse also holds: an envelope rewrite copies broken
Postgres state onto disk. OCFL keeps every version, so `members_dropped` names a
Blob that an earlier version of a FileSet's envelope still recorded. That is the
evidence a repair needs.

## The Atlas check

```bash
bin/rails atlas:health:work NOIDS=abc123def,ghi456jkl
bin/rails atlas:health:work NOIDS=abc123def FIXITY=1
```

It reads the Work as consumers see it, then validates on disk only the objects
Postgres names that owe an envelope: a Derivative FileSet and its Delegates owe
none, because `Classification.preserved?` exempts them. It never builds the
pool-wide index, which a per-Work check cannot afford. It is read-only. `FIXITY=1` re-hashes the bytes; without it,
altered bytes go unnoticed, because a download serves them without a check.

Admins pass every ACL gate, so a broken ACL is invisible to an admin. The check
reads the ACL directly for that reason.

### Over HTTP

[`GET /works/{id}/health_check`](../openapi/openapi.yaml) runs the same check
for Cerberus's Work edit screen. Three things differ from the rake task:

- **It never re-hashes the bytes,** so `fixity_checked` is always `false`. A
  re-hash of a large file would hold a Puma worker for minutes, so fixity stays
  with `FIXITY=1` and `bin/ocfl-health`. A green over HTTP means "nothing is
  missing", not "the bytes are verified". The `fixity` summary reports the
  checks a checker *recorded*; see [`fixity.md`](fixity.md).
- **Only the admin and devolved-admin tiers may call it** (`:read_health`; see
  [`authorization.md`](authorization.md)). Edit rights on the Work do not reach
  it, because the findings describe damage that only those tiers can repair.
- **It is not response-cached,** because a repair changes the answer at once.

### The codes

A client shows a code it does not know rather than failing on it: the
vocabulary grows with the checks. These are the Work-level codes:

| Code | Severity | Repair |
|---|---|---|
| `work_missing` | fatal | None in place; the NOID resolves to no Work |
| `mods_xml_missing` | fatal | A MODS PUT writes the XML again from a known-good source |
| `binary_missing` | fatal | Restore the bytes from backup, or re-deposit the file |
| `fixity_mismatch` | fatal | The same; only with `FIXITY=1` or offline |
| `fixity_failed` | fatal | The same. The object's latest recorded check failed; a passing re-check clears it ([`fixity.md`](fixity.md)) |
| `mods_access_copy_missing` | repairable | `atlas:mods:reproject` rebuilds it from the XML |
| `untitled` | repairable | Edit the MODS |
| `descriptive_file_set_missing` | repairable | A MODS PUT recreates it |
| `orphaned`, `parent_missing`, `wrong_parent_type` | repairable | Re-parent the Work |
| `live_under_withdrawn` | repairable | Withdraw the Work, or restore its parent |
| `staff_edit_missing`, `no_depositor` | repairable | Patch the ACL; the create `AuditEvent` names the depositor |
| `no_content`, `empty_file_set`, `dangling_member`, `blob_unlinked` | repairable | Relink the bytes; the offline check shows whether disk still holds them |
| `blob_metadata_missing` | repairable | Set the Blob's MIME type and filename |
| `not_indexed` | repairable | `POST /resources/{id}/reindex` |
| `envelope_missing`, `envelope_stale` | repairable | Rewrite the envelope (`atlas:preservation:backfill_envelopes`) |
| `flagged_incomplete` | repairable | Rerun the Cerberus job that set it |
| `in_progress`, `withdrawn`, `private`, `no_handle` | advisory | None; a state, not damage |

Every other code comes from validating an OCFL object, one per rule in
`lib/ocfl_health/object_validator.rb` and `envelope.rb`, and its message names
the file at fault.

## The rubric

The destructive probe built a healthy, public, completed Work. Then it broke one
part at a time and recorded what every consumer surface answered. These rules
come from that matrix.

### What a viable Work needs

| Part | Without it | Grade |
|---|---|---|
| The Work row in Postgres | Nothing answers | Red |
| MODS XML on disk | Every JSON read still answers from the access copy, so the loss is silent. `/mods.xml` answers 404, and OAI drops the record's MODS | Red |
| Content bytes on disk, intact | Download answers 404, or serves altered bytes. A recorded check that failed says the same | Red |
| A MODS title | Search cannot find it by title; Cerberus shows a blank heading | Yellow |
| The JSON access copy | `/mods` answers 404 and the Work shows no title. `atlas:mods:reproject` rebuilds it from the XML | Yellow |
| The descriptive FileSet | Reads still answer. A MODS PUT recreates it before it writes | Yellow |
| A parent Collection | Absent from every listing; the ancestor trail is empty | Yellow |
| The staff edit group, and a depositor | Staff or the owner can no longer edit; only admins can | Yellow |
| A content FileSet with a linked Blob | `/assets` is empty, so there is nothing to view or download | Yellow |
| A Blob's MIME type and filename | Download falls back to the type read from the bytes and the stored file's name | Yellow |
| The Solr document | Search and OAI miss the Work until `POST /resources/:id/reindex` recreates it | Yellow |
| The on-disk envelope, current with Postgres | Nothing a consumer sees. A rebuild from disk would lose or misplace the Work | Yellow |

### What a Work can lack and stay green

Every MODS field except the title: the probe stripped a record to its title
alone and every surface answered. A Work can also lack keywords, an abstract,
names, a handle, a classification, an embargo and a public read group. A Work
with no read group is private, not broken.

`in_progress` and a withdrawal are states, not damage, so they are advisory. A
Work still in progress is hidden from OAI and from Cerberus's public view; the
advisory gives the date the deposit opened, so a stuck one stands out.

## Rerunning the probe

```bash
bin/spec spec/exploration/work_health_probe.rb
```

It is named `*_probe.rb` so the suite's `*_spec.rb` pattern never loads it, and
CI never runs it. It writes the matrix to `tmp/work_health_matrix.md` and
`tmp/work_health_matrix.json`, and the cause of each 500 to
`tmp/work_health_raises.log`. Rerun it after a change to a read path or a
repair path, and compare the matrix.

Each mutation is its own example. Run as one example, every fixture stays in one
transaction, and the storage-footprint walk slows with each one added.
