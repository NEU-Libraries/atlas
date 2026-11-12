# Legacy pids

A Community, Collection or Work migrated from v1 records the v1 pid it came
from, such as `neu:1234`. Old public URLs and citations name that pid, so a
client that receives an old URL asks Atlas which object the pid became and
redirects to it.

The map lives on the objects themselves, so it cannot fall behind them, and a
repository reset removes it with them.

Code:

- `app/lib/legacy_pid.rb` — the shape, the holder lookup and the claim every
  creator runs
- `app/queries/find_resource_by_legacy_pid.rb` — the query behind both
- `app/controllers/concerns/supplied_legacy_pid.rb` — the admin gate on a create
- `app/controllers/legacy_pids_controller.rb` — `GET /resources/legacy/:pid`

## Recording a pid on create

`POST /communities`, `POST /collections` and `POST /works` take an optional
`legacy_pid`. The creator records it on the resource's **first** save, so no
moment exists in which the object is visible without it.

| Rule | Why |
|---|---|
| Admins only (`:supply_legacy_pid`), else `403` before anything is created | The migration runs as an admin, and no human deposit has a v1 pid. A delegated admin may supply a handle but not a pid ([`authorization.md`](authorization.md)) |
| Matches `\Aneu:[^/.?]+\z`, else `422 invalid_legacy_pid` | The pattern Cerberus's v1 routes accept, so every recorded pid is one an inbound URL can name |
| Unique across every type, live or tombstoned, else `409 legacy_pid_taken` | One pid names one object. The body's `resource_id` names the holder, so a migration that crashed between the create and its own bookkeeping can recover without parsing the message |
| Set at create only | A wrong pid means purge and re-create, which frees it. No update path accepts it |

**The uniqueness check runs under a Postgres advisory lock** keyed on the pid,
so two concurrent creates with the same pid cannot both pass it. The lock is per
session rather than a transaction, because the create also writes Solr and
OCFL, which no rollback could undo. A Work create that also brings a handle
takes the pid lock first, then the handle lock, always in that order.

**A tombstoned resource keeps its pid**, as a tombstoned Work keeps its handle.
The old URL then lands on the tombstone page.

The pid reaches Solr as `legacy_pid_ssi` with no custom indexer, and rides the
preservation envelope (schema v10, see
[`resource-graph.md`](resource-graph.md)), so a rebuild from disk keeps the v1
correspondence. The three JSON views render it.

## Finding an object by its pid

`GET /resources/legacy/:pid` answers `{"resource": {"id", "type",
"tombstoned"}}`, or `404`.

- **A caller who may not read the holder gets `404`**, the same answer as an
  unknown pid, so the lookup never hands out the NOID of an object it would
  refuse. The system role reads past the per-resource gate, so Cerberus can
  resolve a pid for any visitor; the destination page then applies the
  visitor's own gate.
- **A tombstoned holder is answered, flagged.** The client redirects to it, and
  the destination shows the tombstone.
- **The answer is a body, not a `302`.** A redirect would cost the client two
  round trips on every old URL.
- **The answer is never cached.** A reset re-uses NOIDs, and a cached answer
  would outlive the object it names.
- **A value that is not a pid answers `404`**, as an unknown pid does: it finds
  no holder. The route sets `format: false`, so the path takes no `.json`
  suffix.

The read matrix crosses the lookup with every tier: its Work carries the pid
`neu:matrix-work`, which the runner puts in the path.

## Not yet

A Blob (a v1 content object) and a Compilation (a v1 Set) can carry a pid too,
once their migrations exist. A Blob needs only the attribute and the param,
because the query has no type filter. A Compilation is an ActiveRecord row, so
it needs a column with a unique index, and the lookup must check its table as
well.
