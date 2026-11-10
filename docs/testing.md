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
bin/parallel-spec              # six workers
bin/parallel-spec -n 8         # eight
```

Six is the default because it was measured, not guessed. On a 14-thread laptop
with two performance cores, the whole suite took 635 seconds with four workers,
472 with six and 435 with eight. Past six, each added worker runs on a slower
efficiency core and shares Postgres and Solr with the rest, so the gain falls
away while the machine gets busier. Memory was not the limit: with eight
workers, the VM kept 2.8 GiB free. Re-measure on a machine with a different
core count, and pass `-n` there rather than changing the default.

Each worker is one Ruby process using about one core. The request specs run
through Rack::Test in that process, and the integration specs run Puma as a
thread inside it, so no Puma setting changes how many cores the suite uses.

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
solr loses them — run `bin/parallel-solr-cores 6` again after any stack rebuild.
The databases need no such step; `rake parallel:prepare` creates and migrates
them, and `rake parallel:spec` calls it.

## Specs that run without a Solr index

Most of a service or request example's time goes on building its fixtures, and
about a fifth of every creator's time goes on indexing each save into Solr. A
spec file that never reads Solr gains nothing from that, so the files listed in
`spec/no_index_files.txt` run on Postgres alone: `spec/support/no_index.rb`
switches their examples to a `:test_postgres_only` adapter, which keeps the
response-cache eviction and drops the index. `spec/services` runs in about half
the time that way.

**A listed example that reads Solr raises.** An empty index would otherwise let
a spec that checks something is absent from search pass for the wrong reason.
The error names the line to remove from the list. Writes to Solr, such as an
explicit `Atlas.reindex`, are allowed, and the Solr core is wiped after any
listed example that made one, so a later search does not find it.

Every Solr request goes through `RSolr::Client#execute`, so that one point
decides what counts as a read: any request but an `update`.

**The list keeps itself.** During any run of whole files, the same hook records
which files read Solr. A run without line or tag filters writes the files that
ran, passed and read nothing to `tmp/no_index_candidates<N>.txt`, one per
parallel worker. A file that tags its own examples `:no_index` is left alone.

```bash
bin/no-index-candidates            # list the candidates
bin/no-index-candidates --apply    # add them to spec/no_index_files.txt
```

To see why a file is not a candidate, run it with `NO_INDEX_DEBUG=1`: each Solr
read it makes is printed with the app frame that sent it.

Applying is safe without review, because the guard catches a wrong entry on the
next run. Running it after every whole run suits a local hook. Hooks are per
developer and stay out of the repository; two that work:

- **After `bin/parallel-spec`,** in a shell alias or wrapper:
  `bin/parallel-spec && bin/no-index-candidates --apply`.
- **A Claude Code `PostToolUse` hook** on `Bash`, in your own
  `.claude/settings.json`, that runs `bin/no-index-candidates --apply` when the
  command was `bin/parallel-spec` and it succeeded.

Commit the change to `spec/no_index_files.txt` with whatever change caused it.

## Solr commits once per read, not once per save

A Solr add is stored at once but becomes searchable only when a commit opens a
new searcher. Valkyrie soft-commits on every save, and in the suite that is
almost all wasted: a sample of request and integration specs made over 4,700
Solr updates for 13 reads, and each commit cost several milliseconds.

So `spec/support/lazy_solr_commit.rb` turns the `:test_solr` adapter's commit
on save off, and commits on demand instead. It sits on
`RSolr::Client#execute`, the same point the no-index guard uses. It notes each
write once Solr has taken it, and before any read it sends one soft commit if a
write is pending. Every read therefore sees every write that finished before it,
which is all the per-save commit promised.

**It is safe only because the suite is one process.** The integration specs'
Puma server is a thread in the same process, so its reads pass through the same
hook. Production cannot do this: Cerberus reads the same core directly, and a
flag in one Atlas process cannot know what another process wrote. Production
keeps the commit on every save.

**The adapter itself still commits on save.** Both halves of the shortcut live
in the support file, which only Atlas's own spec run loads. An Atlas server
started with `RAILS_ENV=test`, such as the one Cerberus's suite drives through
`atlas_rb`, uses the same `:test_solr` adapter without that file, so it must
commit every save itself. Otherwise Cerberus would create a fixture and never
find it. `spec/config/solr_connection_spec.rb` boots a test-environment Atlas
without the spec support and checks that it commits.

Two things follow in the suite. A failure to open a searcher shows up on the
next read, not on the save that caused it. And a spec that searches Solr with
anything but RSolr sees no save that has not yet been read past — see
`spec/lib/lazy_solr_commit_spec.rb`, which does exactly that on purpose.

## The suite's storage skips fsync

The OCFL adapter fsyncs every staged file, every directory it publishes into and
every log line, so a crash cannot leave Postgres recording a version the disk
does not hold ([`preservation.md`](preservation.md)). Each fsync is a wait on
the disk, and in the suite they added up to most of the time spent writing
binaries.

The suite's storage is deleted at the start of every run, so it has nothing to
lose in a crash. The `:test_disk` adapter is therefore built with
`durable: false`, which skips every fsync and nothing else: the same staging,
renames and inventories run, so every OCFL spec still sees a real object on
disk.

**`:disk` must stay durable.** `spec/lib/valkyrie/storage/ocfl_spec.rb` fails if
the preservation adapter is ever built non-durable. The same file checks that a
durable adapter syncs each step, using an adapter of its own, so the suite still
proves the fsyncs happen.

Unlike the lazy Solr commit, this setting is in the initializer, so any Atlas
started with `RAILS_ENV=test` gets it, including the server Cerberus's suite
drives. That is deliberate. Skipping fsync changes only what survives a crash,
never what a reader sees, and a test lane's storage is as disposable as the
suite's.

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

## Three guards worth recognising

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

**An example that hangs fails, and says why.** `spec/support/example_watchdog.rb`
gives every example `ATLAS_SPEC_WATCHDOG` seconds, 900 by default; `0` switches
it off. The slowest healthy example, a write-matrix state under six parallel
workers, takes about three and a half minutes. Past the limit the watchdog writes
`tmp/spec-watchdog-<worker>-<time>.log`: every Ruby thread's backtrace, the test
database's `pg_stat_activity`, an `EXPLAIN` of each query running longer than 30
seconds, and the tables with the most dead rows, with the row and page counts
the planner reads for each (see [below](#the-planner-keeps-an-honest-row-count)).
It then cancels the example's
query and, if the example is still running ten seconds later, raises into it. An
example that rescues the cancellation and finishes still fails.

The watchdog reads the database over a connection of its own, outside the pool.
A transactional test pins one connection and shares it with every thread, so a
pooled connection would be the example's, waiting on the query that hangs.

## The planner keeps an honest row count

Postgres plans each query from the row and page counts it last recorded for a
table, `reltuples` and `relpages` in `pg_class`. The suite empties its tables
constantly, and a vacuum that runs mid-suite can record a state no real table
has: zero live rows over pages it could not truncate, because an open example
held a lock. The planner reads that as zero rows per page, so it estimates one
row for a table a spec is filling.

The footprint query (`StorageFootprintQuery`, see [`binaries.md`](binaries.md))
turns that estimate into a hang. Planned for one row, its recursion walks every
row of `orm_resources` at each step and scans the table again for each one. Its
cost then grows with the square of the rows, and a write-matrix state, one long
transaction re-indexing its owners hundreds of times, ran past the watchdog's
900 seconds. With the estimate forced into that state, a single write-matrix
state made the query about thirty times slower even at 200 rows.

So `spec/support/planner_stats.rb` turns autovacuum off for every table in the
test database and vacuums each one at the start of a run, while nothing holds a
lock and every table truncates to nothing. The planner then estimates from each
table's real size, however a spec fills it. Only the test databases are
changed: the setting is a table option written by the suite, not by a
migration, so development and production keep autovacuum.

Without autovacuum, the rows that rolled-back examples leave behind wait for the
next run's vacuum. Postgres prunes most of them as it reads the pages, and a run
is short enough that the rest do not matter.

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

## The access matrices

Six matrices ask one question of every route: what does each caller get, in
each state a subject can be in? The specs for each endpoint test what that
endpoint does. They cannot see a hole between two endpoints that are each
correct: a tombstone that withholds a Work's record while its bytes stay
reachable through `/files/:id/content`. A matrix tests the promise a state
makes across every route instead.

| Matrix | Spec | Routes | States |
|---|---|---|---|
| Read | `access_matrix_spec.rb` | every read of the resource tree | live, private, the four tombstones, embargoed, tier gated, readable by one group, purged, unattached |
| Write | `write_matrix/<state>_spec.rb` | every write to the resource tree | live, the four tombstones, maintenance; private as refusals only |
| Sets | `set_matrix_spec.rb` | Compilations | a public Set, a private Set |
| People | `people_matrix_spec.rb` | Persons | live, maintenance |
| Accounts | `account_matrix_spec.rb` | the user directory, accounts, tokens | live, maintenance |
| Services | `service_matrix_spec.rb` | operator, backend and public endpoints | live, maintenance |

Each table lives in `spec/support/matrices/`, apart from the spec that sends its
requests, so `bin/acl-coverage` can read every row without RSpec.

### Callers

Every caller is defined once, in `MatrixTree` (`spec/support/matrices/tree.rb`),
by what it holds in the fixture world, and every expected cell is derived from
those sets. The callers between them reach each way Atlas grants or refuses
access:

- **Credentials:** a guest with no token; a signed Cerberus assertion; an
  assertion carrying an `obo` claim, from the admin (`:acting_admin`) and from a
  standard user, who is refused (`:obo_refused`); the editor on a read-write
  personal token (`:jwt_editor`) and the admin on a read-only one (`:read_only`);
  the system token; the fixity token.
- **Grants on the Work:** `edit_users` (`:editor`), `edit_groups`
  (`:group_editor`), depositor ownership alone (`:owner`), membership of a read
  group (`:group_reader`), the staff group Atlas prepends to every resource
  (`:staff`), and an edit grant on the containers but not the Work
  (`:curator`).
- **Roles:** `:standard`, `:loader` and `:privileged` without the admin group,
  all standard at the wire; the delegated admin; `:system`; the admin.

### What the read matrix checks

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

When you add a state that withholds something, add it to `STATES` and say in
`WITHHELD` which resources it withholds. Then let the failures show which
routes disagree.

### What the write matrix checks

Each row names a policy (`:edit`, `:operator`, `:admin`, `:reindex`,
`:create_work`, `:create_container` or `:link_member`) and the status a
permitted write answers. A permitted caller then meets the tombstone gate: below
the operator tiers, a write to a tombstoned resource answers 410. A row that
runs no gate, such as `restore`, says `gate: false`, and a row whose service
refuses a tombstoned node or target says so in `refuses:`. A route that needs a
second row, such as the one `:system` grant on linked members, takes an
`@variant` suffix.

Three checks go beyond the status:

- **A refused write changes nothing.** Before each cell that should be refused,
  the spec takes a fingerprint: every resource's last write, the audit rows and
  the idempotency keys. After the refusal, the fingerprint must match. This
  catches a write that changes something and then raises, and a refusal that
  still audits.
- **The permitted cells must succeed.** The admin's cell in the live state
  expects the row's success status, so a row with a wrong payload fails instead
  of passing as a refusal.
- **A permitted write rewrites the envelope.** After each cell that succeeds,
  every resource written since the world was last sealed must have an envelope
  that agrees with Postgres, in both `relationships.json` (or `properties.json`)
  and `permissions.json`. The failure names the resource and the keys that lag.
  The fixtures grant and publicize with bare saves, so
  `AccessMatrixFixtures#seal!` rewrites every lagging envelope after the world
  is built, after a state is applied and after each scratch subject, and again
  after a write the check has failed, so the next cell is not blamed for it. If
  any resource has gone, the scan covers every resource, because a graph names
  its members by NOID and a purge does not save the resource that names it.

  A write proves this only if it changes a value the envelope carries. So the
  `resources#update_permissions` row adds a read group and the
  `works#update_derivative_permissions` row reserves a tier, rather than
  sending back what the Work already holds. A new row for a write to an
  envelope field must do the same.

A successful write changes the world for the next cell. The callers run from
the least privileged to the most, so most rows refuse until their last cells.
A row whose success damages its subject, such as `tombstone`, `destroy` or
`update_parent`, says `fresh: true`. It writes to a throwaway copy of its
subject, which `AccessMatrixFixtures#scratch` builds in the shape the state
gives the shared one, and it takes a new copy after each success. The shared world is
built once per state, because rebuilding it costs about four seconds.

Each state runs from its own file, `spec/requests/write_matrix/<state>_spec.rb`,
through the shared examples in `spec/support/write_matrix_runner.rb`. A state
takes a minute or two, and `parallel_tests` splits the suite by file, so the
matrix as one file put ten minutes on a single worker. `acl_coverage_spec.rb`
fails if a state in `WriteMatrix::STATES` has no file.

A private Work changes no write cell: the Work's editors hold the grant either
way, and nobody else could write. So the private state is not a full run. One
example sends every refused cell against the private Work and expects 403,
never a 404 that would hide whether the Work exists.

### The flat matrices

Sets, People, accounts and the service endpoints have no resource tree, so their
tables share one cell rule, `FlatMatrix`. A row names the callers it admits and
the status a permitted call answers. `write:` applies the read-only token and
the maintenance window; `no_auth:` marks an action that skips authentication.
`spec/support/flat_matrix_runner.rb` sends the rows and applies the same
fingerprint check to a refused write.

`GET /reset` is sent with the environment guard closed, as production has it,
so a permitted reset would show as a miss rather than wipe the world.

## Access-control coverage

`bin/acl-coverage` reports five numbers, from the routes, the controllers'
source and the matrix tables:

| Number | What it counts |
|---|---|
| M1 route inventory | routed actions with a matrix row or a written reason |
| M2 matrix depth | routed actions a matrix crosses with every caller and state |
| M3 gate conformance | routed actions that break no conformance rule |
| M4 asserted cells | rows × callers × states, across the matrices |
| M5 axis reach | the ways of being granted or refused access (`ACLAxes`) that a matrix exercises |

Gate conformance reads the controllers with Prism and follows calls through each
controller's helpers, its concerns and `ApplicationController`, so a gate called
from a helper counts. Two rules apply:

- Every routed action reaches `authorize!`, or carries a reason in
  `ACLMatrices::PUBLIC`. A controller outside `ApplicationController`, which
  `check_authorization` never reaches, must be listed there.
- Every action of a resource controller keyed on `:id` reaches a tombstone gate,
  or carries a reason in `ACLMatrices::TOMBSTONE_EXEMPT`.

A reason for a route the application no longer draws fails too, and so does a
reason for an action that reaches the gate anyway.

```bash
bin/acl-coverage            # the numbers, and every unreached axis
bin/acl-coverage --check    # fail on a broken rule or a number below the baseline
bin/acl-coverage --update   # raise spec/acl_coverage_baseline.json; it never lowers one
```

The baseline only rises. When a change raises a number, run `--update` and
commit the new baseline with the change. `spec/lib/acl_coverage_spec.rb` runs the
check in the full suite, and CI runs it as its own step.

### Running it on every edit

The check takes a few seconds and needs no database, so it suits a local hook.
Hooks are per developer and stay out of the repository; two that work:

- **A git `pre-push` hook,** `.git/hooks/pre-push`:

  ```bash
  #!/usr/bin/env bash
  exec bin/acl-coverage --check
  ```

- **A Claude Code `PostToolUse` hook,** in your own `.claude/settings.json`, on
  `Edit|Write`, that runs `bin/acl-coverage --check` when the edited path is
  under `app/controllers/`, or is `app/models/ability.rb` or
  `config/routes.rb`.
