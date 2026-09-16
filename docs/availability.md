# Availability: the maintenance window and reset

The repository-wide read-only window, and the destructive bootstrap endpoint that
sits beside it.

Source files:

- `app/models/maintenance_mode.rb` — the flag
- `app/controllers/maintenance_controller.rb` — the endpoints

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

## `GET /reset`

The test and dev bootstrap escape hatch, and the most destructive write Atlas
has. It wipes every table, purges the OCFL storage roots, and re-seeds the
fixture users.

### It runs unauthenticated, on purpose

`skip_before_action :require_auth` plus `skip_authorization_check`. **The
`RESETTABLE_ENVS` guard inside the action is the only gate.**

Wiring auth onto it would break a bootstrap chicken-and-egg: the action wipes and
re-seeds the fixture users, so **the very first call against a fresh test
container has nobody to authenticate as.**

`skip_authorization_check` is what stops the `check_authorization` hook from
tripping on an action that never calls `authorize!`.

### It still refuses during maintenance

Because it skips `authorize!` entirely, the maintenance floor never sees it. So
it gets an explicit `before_action :refuse_during_maintenance` rather than an
exemption. The env guard is a separate concern.

### Why the storage purge is not optional

**The DB wipe resets the NOID minter, so the next seed re-mints the same NOID
sequence** — and without a purge those reminted ids resolve to the *same* on-disk
OCFL objects as prior runs.

OCFL state is cumulative. So each run's `descMetadata.xml` and binaries would
stack onto the prior run's object, **polluting a resource's MODS history with
other resources' content across runs.** Emptying the storage root makes every
reseeded object start at v1 with only its own content.

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

`seed_fixture_users!` creates one user per tier the specs and dev need. One is
worth calling out: `User, Standard` (NUID `000000005`) is the plain Northeastern
depositor tier — no Grouper groups, and not an owner of the seed tree. **It
isolates the standard-versus-staff boundary**, for controls that appear only to a
non-editor and non-owner of a Work.
