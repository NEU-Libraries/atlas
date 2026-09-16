# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Read this before editing this file

**This file is tooling, not documentation.** It is tracked so the team shares
one set of working instructions and can review changes to them, but it is
deliberately *not* load-bearing for Atlas itself.

AI coding tools change fast and are interchangeable. This file will be rewritten
for a different assistant, or deleted, without that touching the repository's own
knowledge. So it holds two things only: instructions about **how to work here**,
and short pointers into the durable record.

**The dependency points one way: this file may cite `docs/`, and `docs/` must
never cite this file.** `docs/` and the specs are self-contained; a developer
with no AI tooling loses nothing by ignoring this file. If you find yourself
about to explain a design decision here, that explanation belongs on a `docs/`
page — write it there and link to it.

`.claude/` stays gitignored. Hooks are per-developer tooling and each developer
installs their own; `docs/README.md` says how to measure comment density without
the hook.

## What this is

Atlas is the JSON API for Northeastern University Library's institutional
digital repository (the DRS). It is the system of record for the content
graph (NOIDs, MODS metadata, the resource hierarchy, and binary streams).
It does **not** handle browser sessions or SSO — that's
[Cerberus](https://github.com/NEU-Libraries/cerberus)'s job. The canonical
Ruby client is [atlas_rb](https://github.com/NEU-Libraries/atlas_rb), which
the integration tests use to hit a live Puma instance.

Stack: Rails 8.1 (`ActionController::API`) on Ruby 3.4, Postgres 14, Solr
(Blacklight image), Valkyrie for metadata persistence, a custom Valkyrie
OCFL storage adapter (`app/lib/valkyrie/storage/ocfl.rb`) for binaries,
jbuilder for responses, devise + devise-jwt for the user-token auth path,
rswag for spec-driven OpenAPI.

## The preservation-first principle (read this first)

The DRS is at its heart a **preservation system**, not just an API. The on-disk
MODS XML and binaries are the source of truth. Atlas, Postgres, Solr and the
JSON access copy are derived and disposable: they can be rebuilt from the XML
and binaries, and the XML and binaries cannot be rebuilt from them.

The test: if everyone on the project were hit by a bus, a new hire with disk
access alone should be able to reconstitute important Northeastern Works.

**[`docs/preservation.md`](docs/preservation.md) states the principle in full**,
including the three rules that follow from it and the test that decides whether a
new derived field belongs in the OCFL envelope. Read it before any change to
storage, metadata serialization, or persistence.

## Development commands

Everything runs in docker compose; the dev compose mounts the working tree
into the container so edits are live.

```bash
docker compose up -d                                              # web + db + solr
docker compose exec web bundle exec rake                          # full test suite
docker compose exec web bundle exec rspec spec/requests/works_spec.rb       # one file
docker compose exec web bundle exec rspec spec/requests/works_spec.rb:42    # one example
docker compose exec web bundle exec rubocop                       # lint
bin/openapi                                                       # regenerate openapi/openapi.yaml
```

`bin/openapi` is a thin wrapper — it runs `rake rswag:specs:swaggerize`
inside the container if web is up, otherwise on the host. CI runs the same
generator and fails the build if the committed `openapi/openapi.yaml` differs
from what the specs produce, so any change to a request spec or jbuilder
partial requires a regenerate-and-commit.

The web container's entrypoint runs `db:create` + `db:migrate` on boot
(`docker-entrypoint.sh`), so a fresh checkout is one `docker compose up -d`
away from a working API at `http://localhost:3000`. Interactive docs render
at `/docs` (Scalar); the raw spec is at `/api-docs/openapi.yaml`.

## Architecture

### Resource hierarchy

`Community → Collection → Work → FileSet → Blob`. Every resource is a
`Valkyrie::Resource` subclass of the abstract `Resource` model
(`app/models/resource.rb`) and carries a NOID in `alternate_ids`. The shared
`Relationships` concern overrides `.find` to resolve a NOID first
(`find_by_alternate_identifier`) and only fall back to a Valkyrie ID lookup —
so anywhere in app code, `Work.find(noid)` and `Work.find(valkyrie_id)` both
work. Parent/child traversal goes through `find_inverse_references_by` and
`find_members` on the metadata adapter; the API surfaces this as the
`/<resource>/:id/children` and `/ancestors` routes.

`GET /resources/:id` is the generic NOID resolver — it 302-redirects to the
typed endpoint (`/works/:id`, `/collections/:id`, etc.).

### Persistence: composite Valkyrie adapter

`config/initializers/valkyrie.rb` registers a `:composite_persister` adapter
that writes through Postgres **and** Solr on every save (queries go to
Postgres). The test environment uses `:test_composite_persister` (same
shape, separate Solr core). `MODSIndexer` (`app/indexers/mods_indexer.rb`)
is the project-specific Solr indexer composed alongside Valkyrie's
`AccessControlsIndexer`. Two convenience accessors live in this file:
`Atlas.persister` and `Atlas.query` — prefer them over the verbose
`Valkyrie.config.metadata_adapter.persister/query_service` chain.

Binary storage uses Valkyrie's disk adapter rooted at `/home/atlas/storage`
in the container (`tmp/files` for tests).

### MODS metadata: dual representation (preservation + access copy)

Each Work (and other Modsable resource) stores its descriptive metadata two
ways simultaneously:

1. **XML — the preservation copy.** Written into a special
   "descriptive metadata" `FileSet` (created automatically by `WorkCreator`)
   as a `Blob` whose `descriptive_metadata_for` points back to the
   resource. MODS XML is the canonically correct preservation medium for
   library metadata, but it's dense, hard for humans to read, and slow to
   parse and load at request time.
2. **JSON — the access copy.** A row in `metadata_mods` (a `Metadata::MODS`
   `ApplicationRecord` using `attr_json` for the structured fields, see
   `app/models/metadata/mods.rb`). Fast to read, easy to project into HTML,
   downstream Wordpress instances, etc., without recomposing MODS on every
   hit.

This dual representation is one of the things that differentiates Atlas
from standard ActiveRecord apps and from DRS V1. **The design tradeoff is
explicit: writes can be slow (sync both sides), as long as reads are fast.**
When touching MODS code, favor the read path — don't introduce per-request
Nokogiri parsing on access endpoints; push extraction work into the write
path. If you reach for Nokogiri in a controller or decorator, that's a
smell.

The `Modsable` concern (`app/models/concerns/modsable.rb`) keeps the two
representations in sync: `mods_xml=` writes the blob **and** re-extracts
JSON via `mods_json=`. The conversion logic is split across
`app/lib/mods_*.rb`: `MODSAssignment`, `MODSBuilder`, `MODSExtraction`,
`MODSToJson`, `MODSDecoration`. `mods_builder.rb` is the long XML template
(excluded from rubocop class-length checks).

### Service objects for creation

`app/services/{work,collection,community,file_set,blob}_creator.rb` —
inherit from `ApplicationService`, called as `WorkCreator.call(parent_id:
…)`. Use these (not raw `Resource.new` + `persister.save`) so cross-cutting
side effects fire correctly — e.g. `WorkCreator` automatically creates the
descriptive-metadata FileSet, applies the parent's permissions, and seeds
the MODS template.

### Authentication: four credentials through `require_auth`

`ApplicationController#require_auth` (`app/controllers/application_controller.rb`)
runs before every action and resolves `@current_user` from the bearer token.
(The legacy shared-secret `cerberus_token` relay was **retired** — Cerberus now
signs; see `~/docs/cerberus_token_retirement_primer.html`.)

1. **Blank token → guest.** A real `User` row with the `:guest` role and no
   permissions. Reads generally fall through here; writes are expected to have
   been authorized upstream by Cerberus.
2. **`system_token` + `User: NUID <system>` → the `:system` fixture.**
   atlas_rb's System namespace token; pairs only with `:system` (401
   otherwise). Identity comes from the header.
3. **A valid devise-jwt → that real person (standalone-API path).** Minted by
   `POST /nuid` (system-gated, called by Cerberus post-SSO) and used directly
   by librarians' scripts as `Authorization: Bearer <jwt>`. Decoded via the
   warden `:jwt` strategy, so the JTIMatcher revocation (jti rotation) and
   `exp` (1-week TTL) checks run natively. **Identity comes from the token —
   the `User` header is ignored** — and `:system`/`:anonymous` are rejected.
4. **A valid Cerberus signed assertion → that real person (THE relay).** A
   short-lived JWT signed by Cerberus's *private* key (`iss=cerberus`,
   `aud=atlas`), verified against Cerberus's public keyset
   (`credentials.cerberus_signing_keys`, `kid → PEM`). **ES256 is pinned** (never
   HS256 — blocks the public-key-as-HMAC alg-confusion attack — never `none`);
   `iss`/`aud`/`exp` enforced, 30s leeway. Identity is the proven `sub`, not a
   header. **Acting-as** rides a signed `obo` claim (operator = `sub`,
   admin-only; target attributed downstream) — never a forgeable `On-Behalf-Of`
   header, which is overwritten/ignored on this path. Empty keyset leaves the
   path inert.

Anything else is **401**. Auth itself can return **400** (missing/unknown NUID
under `system_token`, or an unknown assertion `sub`), **401** (unrecognized
token, system-pairing violation, `:anonymous`, expired/revoked/foreign JWT, or
an assertion with a bad signature/`kid`/`aud`/`exp`), and **403** (a signed `obo`
from a non-admin, or an `On-Behalf-Of` header anywhere off the assertion path —
acting-as is admin-only and lives solely on the signed-assertion path).
Endpoint authorization beyond this is enforced via `cancancan` `Ability`.

The devise `sessions`/`registrations` (password sign-in/sign-up) routes are
**skipped** — Atlas never takes a password; human auth is delegated to Cerberus
SSO, which mints JWTs via `POST /nuid`. The devise modules stay on `User` (the
`:user` warden mapping the JWT decoder needs is preserved) for any future
non-SSO service accounts.

### Response shapes: jbuilder ↔ openapi_schemas

Response bodies are defined exclusively in `app/views/{resource}/_{resource}.json.jbuilder`
partials — never inline in the controller, never hand-rolled in `render
json:`. The matching JSON-Schema entries live in `spec/support/openapi_schemas.rb`
and are referenced from request specs by `$ref` (e.g.
`schema '$ref' => '#/components/schemas/Work'`).

Strict schema validation is on (`config.openapi_strict_schema_validation =
true` in `spec/swagger_helper.rb`), so any field added to a partial must
also be added to the schema map (or vice versa) — request specs fail
otherwise. This is the project's primary drift detector. When you change a
partial, expect to update both the schema and `openapi/openapi.yaml`
(via `bin/openapi`) in the same commit.

### Test layers

Three concentric layers in `spec/`:

1. `spec/controllers/` — fast per-action specs.
2. `spec/requests/` — rswag DSL; **doubles as the OpenAPI source**. These
   are the ones that drive `openapi/openapi.yaml` generation. Multipart
   bodies use the custom `multipart_request_body` helper in
   `spec/swagger_helper.rb` (rswag's auto-generated multipart body is buggy
   when several `parameter in: :formData` lines appear — use this helper to
   hand-write the doc shape and pair it with `parameter in: :formData
   type: …` lines that drive runtime serialization).
3. `spec/integration/` — tagged `:atlas_rb_server`. Boots a real Puma server
   via Capybara, points `atlas_rb`'s ENV-driven Faraday connection at it,
   wipes Valkyrie state after each example. Transactional fixtures don't
   apply here (test thread vs. server thread hold different AR connections).
   See `spec/support/atlas_rb_server.rb`.

A `before(:suite)` hook wipes the metadata adapter so a stale Solr/Postgres
test state doesn't leak between runs.

## Conventions worth knowing

- **NOIDs everywhere.** `resource.noid` is the public ID; treat
  `alternate_ids.first` as an implementation detail. `Resource.find` accepts
  either NOID or Valkyrie ID — prefer passing NOIDs.
- **Use `Atlas.persister` / `Atlas.query`** instead of `Valkyrie.config.metadata_adapter…`
  in app code.
- **Decorators** (`app/decorators/*_decorator.rb`) wrap resources with
  view-layer logic (lineage, MODS field accessors). Controllers call
  `.decorate` before assigning to `@resource`; jbuilder partials assume the
  decorated interface.
- **Pagination** for index actions: `include LazyPagination` and
  `paginate_model(Work)` returns `[pagination, items]`. Pagy is configured
  in `config/initializers/pagy.rb`.
- **rubocop** has Atlas-specific exclusions in `.rubocop.yml`. Three files are
  excluded from *every* cop under `AllCops` — `app/lib/mods_builder.rb`,
  `app/lib/mets_builder.rb` and `app/lib/marc_relators.rb`, all data rather
  than logic — and `app/services/**/*` is excluded from `Lint/MissingSuper`
  and `Metrics/ParameterLists`. Don't fight these; the patterns are
  intentional. The baseline is clean, so a new offence is yours.
- **`Rails/DynamicFindBy` whitelist** includes `find_by_alternate_identifier`
  (Valkyrie method, not AR).
- **Comment style.** See [Comments and `docs/`](#comments-and-docs) below. In
  short: a comment explains the *why* of the code beneath it, most of the *why*
  lives on a `docs/` page, and a file targets under 35% comment lines.

## Comments and `docs/`

### Comments explain the *why* of the code below them

A comment earns its place only if it explains why the code immediately below it
exists, and it must still make sense to a reader two years out with **no access
to git history or planning docs**. Keep them to ≤2–3 sentences.

Do **not** write temporal or working-artifact comments:

- **No** dates or app-version stamps (`(Fixed YYYY-MM-DD)`, `0.6.x`).
- **No** workstream shorthand: `piece N`, `Q<n>`, `Gap C`, `gap_reports/`
  pointers, or named initiatives.
- **No** before/after narration — "used to", "no longer", "previously", "was X,
  now Y". Describe the *current* design and its reason; the old design lives in
  git.

Do keep genuine non-obvious rationale, wire-contract constraints, and real
gotchas — but **de-date them**: keep the lesson, drop the incident. A genuinely
deferred fix is a one-line `TODO:`, not a paragraph. This is a *why*-comment
standard, not a no-comments rule.

### Most of the *why* lives in `docs/`, not in the file

Read **[`docs/README.md`](docs/README.md)** before adding a file header. Atlas
keeps knowledge in four places — code, specs, the generated OpenAPI spec, and
`docs/*.md` — and the last holds the per-component explanation that would
otherwise accumulate as long headers: the MODS field registries, the four
credential paths, the OCFL write-path argument, Solr field derivations, and why a
design rejected the obvious alternative.

Never restate a response shape on a page. `openapi/openapi.yaml` is generated
from the request specs, so it cannot drift; a page links to the endpoint and
explains what the schema cannot express.

What that leaves in the source file is the **trap**. Ask: would someone editing
*this line* break something without this comment? A wire-contract gotcha, an
ordering constraint, a rule that looks redundant but is not, and every
`rubocop:disable` justification stay inline. Everything else goes on a page, and
the file keeps a one-line pointer to it.

Target comments under ~35% of a file's non-blank lines, and know that it is a
target rather than a gate — if a comment would cost someone a bug, keep it and go
over. Files under 25 lines of code are exempt, having no denominator to earn a
budget with. A `PostToolUse` hook reports the number after every edit under
`app/`, and names the relevant page when the file already has one. The hook is
developer-local: `.gitignore` excludes `/.claude`, so it does not arrive with a
clone.

Prefer a spec to a page whenever the claim is testable. A spec fails when someone
breaks it; prose does not.

## Testing

Claude can, and should, restart the Rails development server by executing
`docker exec atlas-web-1 bundle exec bin/rails restart` when necessary to
verify changes. This presupposes the developer has the server running,
which was already a pre-existing expectation.

The mechanics live in [`docs/testing.md`](docs/testing.md) — the two spec
wrappers, the per-worker stores, the Solr cores, and the two guards. What
follows is what Claude owes the developer on top of them.

**Plan the verification before starting the work,** and say what you chose when
you report. Naming the specs you judged sufficient is part of the report, so the
developer can see the reasoning rather than just the result.

**Run the specs covering what you touched, then `rake smoke`.** Choosing them is
your call: the files you changed, their callers, and anything your change could
plausibly reach. Do not run the full suite as a matter of routine — CI runs it,
with the coverage floor, on every push. Do run it when the change is broad
enough to warrant it (a bootstrap file, a shared concern, a model everything
touches), and say so when you do.

### Running specs

Use `bin/spec`. It runs rspec inside the web container against whichever
checkout you are standing in, and passes every argument straight through:

```bash
bin/spec spec/requests/works_spec.rb
bin/spec spec/requests/works_spec.rb:42
bin/spec spec/services --example "embargo"
```

It works out where the checkout appears *inside* the container, so the same
command works from the main checkout and from a worktree. **Do NOT** copy
worktree files into the develop checkout to test them — that mutates the
developer's working tree and is a recurring footgun.

A run that names files lifts the coverage floor for itself, so a partial run
fails on the code rather than on arithmetic.

### The whole suite

`bin/parallel-spec` shards it across four workers: about seven minutes against
sixteen in one process. Each worker owns its own database, Solr core and OCFL
storage root.

**Run it detached, and poll for an end marker:**

```bash
docker exec -d -w <worktree> atlas-web-1 sh -c \
  'bundle exec rake parallel:spec > /tmp/run.log 2>&1; echo "DONE rc=$?" >> /tmp/run.log'
```

A foreground `docker exec` that runs for minutes gets killed by the harness — it
watches *free* memory, which Linux keeps small because of the page cache. The
kill takes the host-side client only; the container's rspec keeps running,
**orphaned**, and restarting then stacks orphans that race on the storage roots.
Piping through `tail`, or any pipe, buffers every line until the pipe closes, so
a killed run then leaves no output at all.

The poll must **also** break when no `rspec` process remains and no marker has
appeared, or a killed run looks identical to a slow one. `ps` is not on `PATH`
in the container, so find the process by reading `/proc/*/cmdline`. Do not use
`pkill -f rspec`: the pattern matches the wrapper shell issuing it, so the call
kills itself and the target survives. Kill by PID with the shell builtin,
because `kill` is not on `PATH` either:

```bash
docker exec atlas-web-1 sh -c 'kill -9 <pid>'
```

**After any killed or raced run, before rerunning:** kill the orphan, then
`rm -rf <worktree>/tmp/files*`. The raced OCFL state survives, and a fresh run
trips over it with `Errno::ENOENT` in `fsync_dir`. Those directories have no
tracked `.keep`, so removing them is safe — leave `tmp/.keep`, `tmp/pids/.keep`
and `tmp/storage/.keep` alone.

A truncated example count is the tell that a run was raced or killed. Do not
report it as a result.

### The container mount

The web container bind-mounts only the primary checkout
(`/home/nakatomi/projects/atlas` → `/home/atlas/web`), so a worktree's code is
**not** visible to it by default. The fix is a developer-local, gitignored
`docker-compose.override.yml` at the repo root that also mounts the worktrees
parent dir:

```yaml
services:
  web:
    volumes:
      - /home/nakatomi/projects/worktrees:/home/nakatomi/projects/worktrees
```

The dev stack comes up with an explicit `-f` chain, so a plain override is
**not** auto-merged: a bare `docker compose up -d web` recreates the container
without the working-tree mount, silently, leaving the app on the baked image
copy. Name all three files:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml \
  -f docker-compose.override.yml up -d web
```

### Verification Planning

When planning a task, explicitly think through how you intend to verify the
change before reporting it complete, and capture that as part of the plan. A
convention applies:

- **Preview convention (server / browser checks).** `preview <branch>` (at
  `~/.local/bin/preview`) applies a worktree's **committed** `HEAD..<branch>`
  diff onto the running checkout and restarts the web service, so you can verify
  in the **browser / against the live Puma**. When done, run `preview --revert`
  to clean up. Use it for that purpose only — it requires commits and restarts
  the container, so it is the *wrong* tool for the rspec edit→run→fix loop (use
  `bin/spec`). In-place edits on the developer's working branch need neither —
  the bind mount picks them up directly. See also the
  `preview tool (~/.local/bin/preview)` reference memory.

## Worktree Workflow

- Run a worktree's specs with `bin/spec` from inside the worktree; use
  `preview <branch>` for server/browser verification of the committed branch.
  Never copy worktree files into the develop checkout, and don't invent other
  ad-hoc verification steps.
- Before editing, confirm you are in the correct worktree directory — never
  apply changes to develop or an unrelated worktree.
- Before declaring a worktree complete, run rubocop, `rake smoke`, and the specs
  covering the patch. CI owns the full suite.
- Bump the gem/app version exactly once per worktree on completion; if multiple
  bumps occur, soft-reset and consolidate.
