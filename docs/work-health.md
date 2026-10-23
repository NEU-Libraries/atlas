# Work health

How to tell whether a Work is viable, needs repair, or must be restored or
replaced. Two checks give the same three grades from different sides.

Source files:

- `bin/ocfl-health` and `lib/ocfl_health/` — the offline check, read from disk alone
- `app/services/work_health_check.rb` — the Atlas check, read from Postgres, Solr and disk
- `lib/tasks/health.rake` — `atlas:health:work`
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
Postgres names. It never builds the pool-wide index, which a per-Work check
cannot afford. It is read-only. `FIXITY=1` re-hashes the bytes; without it,
altered bytes go unnoticed, because a download serves them without a check.

Admins pass every ACL gate, so a broken ACL is invisible to an admin. The check
reads the ACL directly for that reason.

## The rubric

The destructive probe built a healthy, public, completed Work. Then it broke one
part at a time and recorded what every consumer surface answered. These rules
come from that matrix.

### What a viable Work needs

| Part | Without it | Grade |
|---|---|---|
| The Work row in Postgres | Nothing answers | Red |
| MODS XML on disk | Every read still answers from the JSON access copy, so the loss is silent. A reindex fails | Red |
| Content bytes on disk, intact | Download answers 404, or serves altered bytes | Red |
| A MODS title | Search cannot find it by title; Cerberus shows a blank heading | Yellow |
| The JSON access copy | `/mods` answers 404 and the Work shows no title. `atlas:mods:reproject` rebuilds it from the XML | Yellow |
| The descriptive FileSet | Reads still answer, but a MODS write answers 500, so the API cannot repair it | Yellow |
| A parent Collection | Absent from every listing; the ancestor trail is empty | Yellow |
| The staff edit group, and a depositor | Staff or the owner can no longer edit; only admins can | Yellow |
| A content FileSet with a linked Blob | `/assets` is empty, so there is nothing to view or download | Yellow |
| A Blob's MIME type and filename | Download answers 500 | Yellow |
| The Solr document | Search and OAI miss the Work, and `reindex` cannot recreate it | Yellow |
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
