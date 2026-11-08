# Testing

The suite is about 1,940 examples. Run the part that covers your change, and
leave the whole suite to CI.

## Running specs

Use `bin/spec`. It runs rspec inside the web container and passes every argument
straight through:

```bash
bin/spec spec/requests/works_spec.rb
bin/spec spec/requests/works_spec.rb:42
bin/spec spec/services --example "embargo"
bin/spec                                    # everything, one process
```

It exists so the same command works from the main checkout and from a worktree.
The two appear at different paths inside the container: the main checkout is
bind-mounted onto `/home/atlas/web`, so its host path does not resolve in there
at all, while a worktree is reachable only through the gitignored
`docker-compose.override.yml` that mounts the worktrees parent at the same path
on both sides. Getting it wrong either fails on `chdir` or silently runs
develop's code in place of the branch's.

SimpleCov enforces `minimum_coverage 90`, and the floor lifts itself for a run
that loaded only part of the suite — a named file, a directory, a parallel
worker's shard. That is decided from what rspec loaded rather than from the
command line, because `rake spec` passes the whole suite either as one
`--pattern` glob or as an expanded list of every file, and no reading of the
arguments tells those apart. A run that names a *tag* still loads every file, so
`rake smoke` sets `SMOKE=1` to lift the floor explicitly.

## The whole suite, sharded

```bash
bin/parallel-spec              # four workers
bin/parallel-spec -n 2         # two
```

Each worker owns its own database (`atlas_test2`), its own Solr core
(`blacklight-test-2`) and its own OCFL storage root (`tmp/files2`). A run wipes
all three at startup, so two workers sharing any one of them would delete each
other's fixtures mid-run.

The suffix comes from `TEST_ENV_NUMBER`, which `parallel_tests` leaves empty for
the first worker and numbers from 2. Worker 1 therefore uses the same stores an
unsharded run has always used, and nothing changes for `bin/spec`.

`bin/parallel-spec` creates the extra Solr cores before it starts the workers.
That step runs on the host, because creating a core means writing a `conf/`
directory into the solr container. The cores live on the container filesystem
rather than in the `solr` named volume, so a `docker compose up` that recreates
solr loses them — run `bin/parallel-solr-cores 4` again after any stack rebuild.
The databases need no such step; `rake parallel:prepare` creates and migrates
them, and `rake parallel:spec` calls it.

## The smoke test

```bash
rake smoke
```

Four examples that answer one question: is this checkout wired up correctly? A
real Postgres write, a real Solr index, a real OCFL object on disk, and a real
HTTP round trip through the API. Each stands in for a failure that would
otherwise surface as a hundred unrelated red examples — a missing worker
database, a core that does not exist, a storage root holding raced state from a
killed run.

It is the cheap gate before a worktree is declared complete. It is not a
substitute for the specs covering the change.

## Two guards worth recognising

**Only one run at a time.** A run empties the OCFL storage root, wipes Postgres
and the test Solr core, and deletes every `AuditEvent`. Two overlapping runs
delete each other's fixtures, and the damage lands in whatever file happened to
be executing — a cluster of failures that pass when that file is re-run alone,
which reads like a bug in that file rather than a collision.
`spec/support/exclusive_run_lock.rb` takes an `flock` per worker and aborts the
second run with a message naming the lock file. The develop checkout and every
worktree share the database and the core even though their storage roots differ,
so the lock lives in the container's `/tmp` rather than in a checkout. Because it
is `flock`, the kernel releases it when a run dies — a held lock always means a
live run, never a stale file.

**A run refuses to wipe the wrong stores.** The database and the Solr core are
both env-derived so that workers can each own one, and an env that resolved to
the development core or the development database would be wiped just as readily.
`spec/support/spec_preflight.rb` checks the environment, the core name, the
database name and the core's ping before the wipe. If it fires, read the
message: it names the fix.

## What CI owns

CI runs the full suite unsharded on every push and pull request, with the
coverage floor, and then regenerates `openapi/openapi.yaml` and fails if the
committed file differs. Do not run the full suite as a matter of routine. Do run
it when a change is broad enough to warrant it — a bootstrap file, a shared
concern, a model everything touches — and say so when you do.

## Test layers

Three concentric layers in `spec/`:

1. `spec/controllers/` — fast per-action specs.
2. `spec/requests/` — rswag DSL, and the source `openapi/openapi.yaml` is
   generated from. Strict schema validation flags response drift, so a field
   added to a jbuilder partial must also be added to
   `spec/support/openapi_schemas.rb`.
3. `spec/integration/` — tagged `:atlas_rb_server`. Boots a real Puma server via
   Capybara and drives Atlas through the `atlas_rb` client over HTTP.
   Transactional fixtures do not apply here: the test thread and the server
   thread hold different Active Record connections.

## The access matrix

`spec/requests/access_matrix_spec.rb` asks one question of every read route:
what does each caller get, in each state a resource can be in? The states are
live, a private Work, a tombstone on a Work, a FileSet, a Collection or a
Community, an embargoed Work, and a Work whose file tier is reserved to a group.
The last two withhold the file bytes and nothing else. The callers are a guest, a standard user, an editor of the Work, a
delegated admin and an admin.

The specs for each endpoint test what that endpoint does. They cannot see a
hole between two endpoints that are each correct: a tombstone that withholds a
Work's record while its bytes stay reachable through `/files/:id/content`. The
matrix tests the promise a state makes across every route instead.

Each route is a row naming a policy, such as `:withheld` or `:read`, and the
policy gives the expected status for each cell. Two checks look at the body as
well as the status:

- **The bytes.** A refused cell must carry none of the file's bytes, and a
  served byte route must carry all of them.
- **The markers.** Each resource carries a unique marker string, in its
  description, its filename or its image URI. Below the operator tiers, no
  response from any route may carry the marker of a withheld resource. This is
  what catches a leak through a route that does not belong to the resource, such
  as a thumbnail URL in another resource's list. The live state proves that
  every marker reaches some response, so the check cannot pass vacuously.

A `POST` that reads, such as `resources#find_many`, takes a row with `post:`.
A route keyed on something outside the resource tree, such as a Set or an
account, goes in `UNSCOPED` with a reason that names where its gate is tested.

The inventory examples read the route table itself. A new `GET` route fails the
spec until it has a row or a reason, so nobody can add a read without deciding
what a tombstone or a private ACL means for it. A row for a route that is no
longer drawn fails too.

When you add a state that withholds something, add it to `STATES` and say in
`WITHHELD` which resources it withholds. Then let the failures show which
routes disagree.

### The write matrix

`spec/requests/write_matrix_spec.rb` asks the same question of every `POST`,
`PUT`, `PATCH` and `DELETE` route: who may change or delete this resource, in
each state it can be in? Both matrices run against one fixture tree, one set of
states and one set of callers, in `spec/support/matrix_world.rb`.

The write matrix adds two callers and one state, and runs the private state as
refusals only (see below):

- **`:system`**, because its scoped grants live on writes: it creates
  containers, reindexes, and links a Work into a featured Collection while
  acting as the Work's depositor.
- **`:read_only`**, the admin on a read-only personal token. Every write must
  answer 403, which proves the token floor holds even for the widest grant.
- **`maintenance`**, the read-only window. Every write must answer 503 for every
  caller.

Each row names a policy (`:edit`, `:operator`, `:admin`, `:reindex`,
`:create_container` or `:link_member`) and the status a permitted write
answers. A permitted caller then meets the tombstone gate: below the operator
tiers, a write to a tombstoned resource answers 410. A row that runs no gate,
such as `restore`, says `gate: false`, and a row whose service refuses a
tombstoned node or target says so in `refuses:`. A route that needs a second
row, such as the one `:system` grant on linked members, takes an `@variant`
suffix.

Two checks go beyond the status:

- **A refused write changes nothing.** Before each cell that should be refused,
  the spec takes a fingerprint: every resource's last write, the audit rows and
  the idempotency keys. After the refusal, the fingerprint must match. This
  catches a write that changes something and then raises, and a refusal that
  still audits.
- **The permitted cells must succeed.** The admin's cell in the live state
  expects the row's success status, so a row with a wrong payload fails instead
  of passing as a refusal.

A successful write changes the world for the next cell. The callers run from
the least privileged to the most, so most rows refuse until their last cells.
A row whose success damages its subject, such as `tombstone`, `destroy` or
`update_parent`, says `fresh: true`. It writes to a throwaway copy of its
subject, which `MatrixWorld#scratch` builds in the shape the state gives the
shared one, and it takes a new copy after each success. The shared world is
built once per state, because rebuilding it costs about four seconds.

A private Work changes no write cell: the editor holds the grant either way, and
nobody else could write. So the private state is not a full run. One example
sends every refused cell against the private Work and expects 403, never a 404
that would hide whether the Work exists.

The inventory works as it does for reads. A new write route fails the spec until
it has a row, or a reason in `UNSCOPED`.
