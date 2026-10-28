# Availability: the maintenance window, health, and reset

The repository-wide read-only window, the health and liveness routes, and the
destructive bootstrap endpoint that sits beside them.

Source files:

- `app/models/maintenance_mode.rb` — the flag
- `app/controllers/maintenance_controller.rb` — the endpoints
- `app/services/repository_reset.rb` and `lib/tasks/reset.rake` — the reset
- `app/lib/system_health.rb` and `app/controllers/health_controller.rb` — `GET /health`

The floors that enforce the window live in `ApplicationController#authorize!` —
see [`authentication.md`](authentication.md). The 503 shape is
[`error-contract.md`](error-contract.md).

## Where the flag lives, and why

**In the database, not an environment variable.** A deploy replaces the
containers, so an env var would be reset by the very deploy that set it.

**In Atlas, not Cerberus.** A Cerberus-held flag is bypassed by any direct API
caller, including a personal access token minted by `POST /nuid`.

It is a single row, created on first read so callers never handle a nil.

## `source` is load-bearing, not decoration

Three doors open the same window: the Cerberus admin hub, the `maintenance:`
rake task, and the deploy orchestrator.

**A deploy that finishes must not close a window a human opened by hand.**

| `source` | Which doors | May close |
|---|---|---|
| `operator` | The admin hub, the rake task | Either kind of window — a human is deciding |
| `deploy` | The deploy orchestrator | A `deploy`-opened window only |

`close!` on a `deploy` source against an `operator` window **leaves the window
standing and returns the unchanged row**, so the caller sees the real state
rather than a false "closed".

An unnamed door defaults to `operator`: that is a human at the hub or the
console. The deploy orchestrator names itself, and is the only door whose close
is restricted.

### Re-opening takes ownership

`open!` on an already-open window re-stamps it with the new source and message,
**so a deploy that starts inside an operator window takes ownership of it.** The
alternative would let the deploy's own close be refused by a source it never set.

## The per-request memo

`ApplicationController#authorize!` consults the flag on **every authorized
action**, so an uncached read would add a query per action.

`MaintenanceMode::Cache` is an `ActiveSupport::CurrentAttributes`, which resets
itself between requests. **So a window opened by another process is seen on the
next request** rather than at process restart.

## The endpoints

### `GET /maintenance`

The window's state, on the authenticated read floor and deliberately so. **If
this were refused during maintenance, Cerberus could never see the flag it is
meant to be honouring.**

### `PUT /maintenance`

Opens or closes the window. `:system` plus admin, matching how the token
endpoints gate an operator action.

**It is the one action that stays reachable while the window is open.**
`read_only_exempt?` returns true here and nowhere else — without it, an open
window would refuse the very request that closes it.

It also emits its own audit row. `PUT /maintenance` is `:system`-gated, so
without that the ledger would record the system principal flipping the flag and
not who asked. **"Who put the repository into maintenance mode, and when" is
exactly the sort of fact the ledger should hold.** It mirrors
`Users::TokensController#audit_token_event`, which has the same
system-gated-but-human-driven shape.

## Health and liveness

Two routes, because an orchestrator and a monitor ask different questions.

| Route | Question | Touches | Called by |
|---|---|---|---|
| `GET /up` | Has the app booted? | Nothing | The compose and Swarm healthchecks |
| `GET /health` | Can Atlas serve its contract? | Postgres, Solr, storage, Redis | Cerberus's `/health`, and Nagios through it |

**Liveness must not probe a dependency.** An orchestrator restarts a container
that fails its healthcheck. If `/up` probed Solr, a Solr outage would restart
every Atlas replica, which fixes nothing and drops the requests that could still
be served.

`/up` is Rails's own `Rails::HealthController`. It inherits
`ActionController::Base`, so neither `require_auth` nor `check_authorization`
applies to it.

### `GET /health`

It answers each dependency as `ok` or `unavailable`, and the cache can also be
`disabled`. The response schema is in `openapi/openapi.yaml`.

| `status` | When | HTTP |
|---|---|---|
| `ok` | Everything answers | 200 |
| `degraded` | Only the cache is down | 200 |
| `degraded` | The index or the storage is down | 503 |
| `unavailable` | The database is down, so no request can even authenticate | 503 |

**It is unauthenticated, and has to be.** Resolving even the guest principal
reads the database, so a probe behind `require_auth` could never report the
database down. It skips `require_auth` and overrides `public_endpoint?`, the
hook that excuses it from `check_authorization`. Because anyone can call it,
the body names no host, version or error text. The detail of each failed check
goes to the log at `error` level, prefixed `health:`.

**The result is memoized for five seconds per process.** A poller cannot turn
it into load on the services it probes. The memo is in process memory, not in
`Rails.cache`, because the cache is one of the things being probed. Its lock
also makes concurrent callers share one probe.

### What each check proves

| Check | Passes when | Bounded by |
|---|---|---|
| `database` | `SELECT 1` answers | The pool's checkout timeout |
| `index` | The core's `admin/ping` answers `OK` | Its own connection: 1s to connect, 2s to read |
| `storage` | See below | No network call |
| `cache` | Redis answers `PING` | The store's 1s connect and 0.2s read timeouts |

The index check builds its own Solr connection because the persister's carries
no timeouts. A hung Solr would otherwise hold the probe past a poller's deadline.

### The storage check, and what it cannot see

Every storage root must be a writable directory. **The first root must also carry
the OCFL marker `0=ocfl_1.1` once anything is deposited.** The first root takes
the repository's first object, and the adapter writes the marker before it.

That second rule is what catches a volume that did not mount. The `Dockerfile`
creates every root's path, so an unmounted volume leaves an empty directory that
exists and is writable. Without the marker rule, the check would pass while
writes landed in the container layer and vanished on restart.

**A later root is checked for the directory alone.** It can legitimately be
empty and unmarked, so the probe cannot tell "new" from "not mounted". A read
that names it still answers `503 backend_unavailable`, through the
`StorageUnavailable` guard in the adapter (see
[`error-contract.md`](error-contract.md)).

If the database is down, the probe cannot ask whether anything is deposited. It
then treats the repository as empty rather than failing storage on the
database's behalf.

## `GET /reset` and `rake reset:clean`

The test and dev bootstrap escape hatch, and the most destructive write Atlas
has. It wipes every table, empties Solr, purges the OCFL storage roots, clears
the response cache, and re-seeds the fixture users.

**Both doors run one service, `RepositoryReset`.** The route calls it from a
request; the rake task calls it in-process, so a reset needs no running Puma.
`rake reset:data` runs `reset:clean` and then adds a sample Community,
Collection and Work.

**A reset must never be written a second way.** A wipe that clears Postgres
and Solr but skips the storage rewinds the minter and leaves every object in
place, so the reseed's reminted NOIDs stack onto other resources' objects. One
service is what keeps every door doing all five steps.

### It runs unauthenticated, on purpose

`skip_before_action :require_auth` plus `skip_authorization_check`. **The
`RESETTABLE_ENVS` guard inside the action is the only gate.**

Wiring auth onto it would break a bootstrap chicken-and-egg: the action wipes and
re-seeds the fixture users, so **the very first call against a fresh test
container has nobody to authenticate as.**

`skip_authorization_check` is what stops the `check_authorization` hook from
tripping on an action that never calls `authorize!`.

### It still refuses during maintenance

Because the route skips `authorize!` entirely, the maintenance floor never sees
it, and a rake task never meets the floor at all. So `RepositoryReset#call`
checks the window itself, before anything is deleted, for every caller. The env
guard is a separate concern.

### Why the storage purge is not optional

**The DB wipe resets the NOID minter, so the next seed re-mints the same NOID
sequence** — and without a purge those reminted ids resolve to the *same* on-disk
OCFL objects as prior runs.

OCFL state is cumulative. So each run's `descMetadata.xml` and binaries would
stack onto the prior run's object, **polluting a resource's MODS history with
other resources' content across runs.** Emptying the storage root makes every
reseeded object start at v1 with only its own content.

### Why the response cache is cleared

The reminted NOIDs collide with the response cache too. `ResponseCache` keys are
`<namespace>/<scope>/<noid>/<audience>` and carry no version, so an entry cannot
tell that its NOID now names a different resource. **Without a clear, a reused
NOID serves the prior run's body — its metadata and its `resources.permissions`
ACL — until the TTL expires.** Atlas's own authorization is unaffected, because
it runs against the live resource before the cache is read.

The normal write path evicts through `CacheEvictingPersister`, but the reset
deletes rows directly and never reaches it. So the action calls
`ResponseCache.clear!`, which deletes only the keys under `ResponseCache::NAMESPACE`.
`Rails.cache.clear` would also work, but it empties the whole `atlas` Redis
namespace rather than the entries this class owns.

The clear is a no-op wherever `ResponseCache.enabled?` is false, which covers test
and a development checkout without `tmp/caching-dev.txt`. Staging always runs
Redis, so staging is where a missing clear shows.

`purge_storage!` removes each root's **children** rather than the root itself,
because the root is a container mount point and the adapter's path has to stay
valid for the re-seed.

An absent root just means nothing to purge — the OCFL adapter creates it lazily
on first write, so test's ephemeral `tmp/files` may not exist on a freshly booted
container. It is created so the guard's directory check passes and the re-seed
has a valid empty store, and that is a no-op when the root already exists.

### Two guards that repeat themselves on purpose

**`delete_all_rows!` re-checks the environment** independently of its caller,
mirroring `purge_storage!`. It empties every table Atlas has, so it must never be
reachable outside a resettable env even if a future caller forgets to check.

**`guard_storage_root!` runs per root**, because one misconfigured entry in the
pool must not be reached through a sibling. It refuses a missing,
non-directory, or dangerously shallow root. The real roots —
`/home/atlas/storage` and `<app>/tmp/files` — are absolute and several segments
deep, **so a root with fewer than two path segments signals a misconfiguration
that must not be `rm_rf`'d against.**

### Why not `database_cleaner`

Reset is reachable in **staging**, and that gem sits in the `:development, :test`
bundle group. `Bundler.require` loads only the running environment's groups,
**leaving the constant undefined in staging.**

The wipe uses `DELETE` rather than `TRUNCATE`, with referential integrity
disabled, so it is order-independent across the tables' foreign keys.

## The fixture users

`seed_fixture_users!` creates one user per tier the specs and dev need, plus the
non-human fixtures: `:system`, `:anonymous` and the `:fixity_checker` the
rolling checker authenticates as ([`fixity.md`](fixity.md)). Without the last,
every sweep after a reset would answer 400 until someone recreated it. One
human fixture is worth calling out: `User, Standard` (NUID `000000005`) is the plain Northeastern
depositor tier — no Grouper groups, and not an owner of the seed tree. **It
isolates the standard-versus-staff boundary**, for controls that appear only to a
non-editor and non-owner of a Work.
