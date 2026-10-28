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
- `app/queries/preserved_object_keys_query.rb` — the objects a Work's rollup
  covers
- `app/services/fixity_result_rebuilder.rb`, `lib/tasks/fixity.rake` — the rebuild
- `app/queries/fixity_due_query.rb` — what to check next
- `bin/ocfl-fixity-sweep`, `lib/ocfl_health/fixity_sweep*` — the checker
- `bin/fixity-entrypoint.sh` — the service that runs it each night
- `app/models/fixity_checker_ability.rb` — the checker's whole ability

## Atlas records checks; it does not run them

[`POST /fixity_checks`](../openapi/openapi.yaml) takes one result per OCFL
object from a checker that already did the hashing. Re-hashing a large file
would hold a Puma worker for minutes, so the request hashes nothing. Only the
`:fixity_checker` principal and admins may post. The devolved-admin tier reads
the results on the health check but cannot write one, because a result is a
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

**These fields are preservation detail for the staff who look after the
repository, not for public discovery.** They exist so an admin report can find
what failed or is overdue. Do not show them in a public catalog, as a facet or
otherwise.

Each object's own latest check sits on the Solr doc of the resource that owns
it, a Work, a FileSet or a Blob, as `fixity_checked_at_dtsi` and
`fixity_result_ssi`.

**A Work's doc also carries a rollup over every object it owns**, the same
summary the health check returns. The catalog hides FileSet and Blob docs, and
Solr cannot take a minimum across them per Work, so the rollup is what lets a
repository-wide query over Works find them:

| Field | Value |
|---|---|
| `work_fixity_checked_at_dtsi` | The oldest latest check; absent while any object is unchecked |
| `work_fixity_result_ssi` | The worst recorded outcome; absent when none is recorded |
| `work_fixity_objects_isi` | The objects the Work owns |
| `work_fixity_never_checked_isi` | Those with no recorded check |

| Question, over Works | Filter |
|---|---|
| Some object's last check failed | `work_fixity_result_ssi:fail` |
| Not fully verified in 12 months | `work_fixity_checked_at_dtsi:[* TO NOW-12MONTHS] OR work_fixity_never_checked_isi:[1 TO *]` |
| Never verified at all | `-work_fixity_result_ssi:[* TO *]` |

The rollup covers the Work, its FileSets other than the Derivative one, and
their Blobs: the set `Work#preserved_resources` names, read in one statement
because the Work's index runs it.

### When the rollup refreshes

It is recomputed whenever the Work is indexed. Recording a check, and a
rebuild, re-index the owning Work through the footprint recorder's batched
owner reindex, so a request touching several of its objects indexes it once.
A deposit, a replaced file and a purge already re-index the owner the same way,
so a new file shows as unchecked at once.

An in-progress Work is the exception, as it is for the footprint: its doc waits
for `POST /works/{id}/complete`, which indexes it.

## The Work summary

[`GET /works/{id}/health_check`](../openapi/openapi.yaml) returns `fixity`, a
summary over the objects the Work reaches (`Work#preserved_resources`). A Work
is only as verified as its least recently checked object, so:

- `last_checked_at` is the oldest of their latest checks, and null while any
  object has never been checked;
- `result` is the worst outcome recorded, or null when none has been;
- `never_checked` counts the objects with no check.

`fixity_checked` stays `false`: it says that the request itself re-hashed
nothing, which is still true.

**A recorded `fail` grades the Work red.** Each object whose latest check
failed adds a fatal `fixity_failed` finding naming that object, because a
failed check means altered bytes, the same loss a `FIXITY=1` mismatch reports.
Only the latest check counts, so after a restore, a passing re-check clears the
finding. See [`work-health.md`](work-health.md).

## The rolling checker

Nothing in Atlas runs on a schedule, and a request must not hash. So the
checker is a separate service: a container built from the Atlas image that
runs `bin/fixity-entrypoint.sh` instead of Puma, reads the storage read-only,
and talks to Atlas over HTTP like any other client.

### What it does each night

The entrypoint wakes every `FIXITY_INTERVAL` seconds. While the UTC hour is
inside the window it runs `bin/ocfl-fixity-sweep`, which:

1. asks [`GET /fixity_checks/due`](../openapi/openapi.yaml) for the objects
   most in need of a check, passing its own start as `checked_before`;
2. re-hashes each one with `OcflHealth::ObjectValidator`, the validator
   `bin/ocfl-health` uses;
3. posts the result to `POST /fixity_checks`;
4. stops when the list is empty, at the window's end, or at the byte budget.

A result is a **fail** when the validator finds anything fatal: bytes missing,
altered or unreadable. A repairable finding, a broken rule with nothing lost,
rides along on a pass. Because each run asks for checks older than its own
start, an object it records drops out of the list, and a restart or a missed
night only leaves more due for the next run.

### Why the due list comes from the storage ledger

`fixity_results` has a row only for an object that has been checked, so it
cannot list the ones that never have been. `storage_footprints` has a row for
every object the adapter has written, so the due list is the ledger
left-joined to the results. An object written before the ledger existed is
missing from it until `rake atlas:storage:rebuild_footprints` runs.

### Rules the service must keep

- **Run exactly one replica.** Two checkers race over the same objects.
- **Mount the storage read-only.** The sweep never writes; the log line is
  appended by Atlas when it receives the post. The entrypoint warns at start if
  a root is writable.
- **Never exit.** Compose and Swarm restart a stopped service, so the loop
  never returns, and a failed sweep is logged and retried on the next wake.
- **Priority is set by the entrypoint** (`ionice -c3 nice -n19`), because a
  host-level setting never reaches a process `dockerd` starts.
- **The window is UTC** and may cross midnight, such as 22 to 4.
- **A maintenance window stops the sweep before it hashes.** The due read is
  refused then, like every non-read action, and the sweep exits on any 401,
  403 or 503.

### The checker's identity

The sweep authenticates as the `:fixity_checker` fixture (NUID `000000098`)
with its own shared secret, `credentials.fixity_token`, paired with that fixture
the way `system_token` is paired with `:system`. See
[`authentication.md`](authentication.md). Its whole ability is
`FixityCheckerAbility`: read the due list, record a result. `Ability` gives the
fixture nothing, so no rule added there can reach it.

To enable it in an environment:

1. Add `fixity_token` to that environment's credentials. The path is inert
   until it is set.
2. Create the fixture: `bin/rails atlas:fixity:checker_user`. It is idempotent,
   and every reset seeds it.
3. Give the service the same secret as `FIXITY_TOKEN`, or as a file named by
   `FIXITY_TOKEN_FILE` for a Docker secret.

### Configuration

| Variable | Default | Meaning |
|---|---|---|
| `ATLAS_URL` | none, required | Atlas's base URL |
| `FIXITY_TOKEN` or `FIXITY_TOKEN_FILE` | none, required | The checker's secret |
| `FIXITY_NUID` | `000000098` | The fixture it pairs with |
| `FIXITY_WINDOW_START`, `FIXITY_WINDOW_END` | `1`, `7` | The UTC hours to sweep in |
| `FIXITY_INTERVAL` | `900` | Seconds between wakes |
| `FIXITY_BUDGET` | none | Stop after hashing this much, such as `500GB` |
| `OCFL_EXTRA_ROOTS` | none | The same value Atlas has, so every root is checked |

With no budget, the window's end is the only bound. Set one where reads cost
money, such as on cloud storage.

### The service definition

```yaml
fixity:
  image: nakatomi/atlas_web:${ATLAS:-latest}
  entrypoint: ["/home/atlas/web/bin/fixity-entrypoint.sh"]
  environment:
    ATLAS_URL: http://atlas:3000/
    FIXITY_TOKEN_FILE: /run/secrets/fixity_token
  secrets: [fixity_token]
  volumes:
    - storage:/home/atlas/storage:ro
  restart: unless-stopped
  cpus: 1
  mem_limit: 256m
```

Declare `fixity_token` under the file's top-level `secrets:` key. Run it on the
same image tag as the Atlas service it reports to, because the
sweep calls endpoints that tag serves. Under Swarm, `restart` becomes
`deploy.restart_policy`, the limits move under `deploy.resources`, and
`deploy.replicas: 1` keeps it to one.

