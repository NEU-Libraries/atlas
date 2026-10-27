# Fixity checks

Atlas records a SHA-512 for every file in every version when it writes the
version: it is in each OCFL object's `inventory.json`. That is the *recorded*
digest. A **fixity check** is the later act of re-hashing the stored bytes and
comparing them with it. This page is about recording that act: when it ran, on
which version, and whether it passed.

Source files:

- `app/controllers/fixity_checks_controller.rb` and `app/lib/fixity_check.rb` —
  the write and its checks
- `app/services/fixity_check_recorder.rb` — the log line, the row, the reindex
- `app/lib/valkyrie/storage/ocfl.rb` — `append_log`, `read_log`, `object_versions`
- `app/models/fixity_result.rb`, `app/indexers/fixity_indexer.rb` — the latest
  check per object, and its Solr projection
- `app/services/fixity_result_rebuilder.rb`, `lib/tasks/fixity.rake` — the rebuild

## Atlas records checks; it does not run them

[`POST /fixity_checks`](../openapi/openapi.yaml) takes one result per OCFL
object from a checker that already did the hashing. Re-hashing a large file
would hold a Puma worker for minutes, so the request hashes nothing. Only the
`:system` principal and admins may post. The devolved-admin tier reads the
results on the health check but cannot write one, because a result is a
checker's output, not a person's judgement.

An object is named by its inventory id, `urn:neu-drs:<noid>`, because that is
what a checker reads off disk. The NOID is the object key, so it also names the
resource that owns the object.

## The log is the record

Each result is appended as one JSON line to `<object root>/logs/fixity.jsonl`.
OCFL 1.1 section 3.8 reserves `logs/` for "a record of actions taken on the
object", outside its versioned content, and gives "an audit was conducted, and
nothing was wrong" as its example. So:

- **Recording a check never cuts a version.** The inventory does not list
  `logs/`, and the version write path never touches it.
- **The history travels with the object.** A librarian with disk access alone
  can read when each object was last verified, in plain text.
- **Two writers cannot interleave lines.** The append holds an exclusive
  `flock`.
- **A retried request records once.** The line has a fixed key order, so the
  same check gives the same line, and a line identical to the last one is
  skipped. The endpoint then answers 200 rather than 201.
- **The bytes count towards the object's footprint,** so the storage ledger
  still equals a walk of the disk. See [`binaries.md`](binaries.md).

`checked_at` is kept to the second, the precision the line carries, so the row
caching a line never disagrees with it.

## The latest check is a cache over the log

`fixity_results` holds one row per object: the newest check by `checked_at`. A
check older than the row is still logged, but it does not replace the row: a
checker that posts late, or a backlog replayed out of order, must not hide a
newer result. `rake atlas:fixity:rebuild` recomputes every row from the logs,
and it re-indexes only the resources whose rows change.

The row is a separate table, not an attribute on the resource, for two reasons:

- **A resource save moves `updated_at`, which is the OAI datestamp.** A sweep
  that saved each resource would make every Work look edited, and harvesters
  would re-fetch the whole repository after each one. See [`oai.md`](oai.md).
- **A save takes the resource's optimistic lock,** so a sweep would race the
  people editing it.

Atlas then re-indexes the owning resource in Solr only, which leaves
`updated_at` alone.

## Querying across the repository

The resource that owns each object carries `fixity_checked_at_dtsi` and
`fixity_result_ssi` on its Solr doc. Both are absent for an object never
checked, so:

| Question | Filter |
|---|---|
| Last check failed | `fixity_result_ssi:fail` |
| Not verified in 12 months | `fixity_checked_at_dtsi:[* TO NOW-12MONTHS]` |
| Never verified | `-fixity_checked_at_dtsi:[* TO *]` |

The fields sit on the doc of the resource that owns the object: a Work, a
FileSet or a Blob. A Work's doc carries only its own object's check. To find
the Works behind failing files, follow each Blob to its Work.

## The Work summary

[`GET /works/{id}/health_check`](../openapi/openapi.yaml) returns `fixity`, a
summary over the objects the Work reaches (`Work#preserved_resources`). A Work
is only as verified as its least recently checked object, so:

- `last_checked_at` is the oldest of their latest checks, and null while any
  object has never been checked;
- `result` is the worst outcome recorded, or null when none has been;
- `never_checked` counts the objects with no check.

`fixity_checked` stays `false`: it says that the request itself re-hashed
nothing, which is still true. A recorded `fail` does not change the grade.
See [`work-health.md`](work-health.md).
