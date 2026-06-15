# Atlas

JSON API for **Atlas** — Northeastern University Library's institutional
digital repository.

Atlas is the system of record for the repository's content graph. It owns
durable identifiers (NOIDs), MODS metadata, the resource hierarchy, and the
binary stream of every file. It does not handle browser sessions or SSO —
that's [Cerberus](#cerberus)'s job.

## How it fits together

```
                        ┌─────────────────────────────────┐
   Browser / SSO ──────▶│            Cerberus             │
                        │ (Northeastern auth gateway)     │
                        └─────────────────────────────────┘
                                      │
                                      │  Bearer <signed assertion>
                                      │  (ES256 JWT, iss=cerberus)
                                      ▼
                        ┌─────────────────────────────────┐
                        │             Atlas               │   ← this repo
                        │ Rails API · Postgres · Solr ·   │
                        │ Valkyrie · jbuilder             │
                        └─────────────────────────────────┘
                                      ▲
                                      │  HTTP
                                      │
                        ┌─────────────────────────────────┐
                        │ atlas_rb (Ruby client)          │
                        │ + any other OpenAPI consumer    │
                        └─────────────────────────────────┘
```

- **Cerberus** terminates user sessions, asserts identity, and forwards
  requests to Atlas as a short-lived **signed assertion** — an ES256 JWT
  whose proven `sub` is the acting user (the relay that replaced the retired
  `cerberus_token` shared secret). The pre-shared system token + `User: NUID`
  header is now scoped to SSO first-login provisioning of the `:system`
  principal.
- **[atlas_rb](https://github.com/NEU-Libraries/atlas_rb)** is the canonical
  Ruby client; it reads `ATLAS_URL` / `ATLAS_TOKEN` and wraps every
  endpoint as a class method.
- Any other consumer (codegen, agents, curl) can drive Atlas straight from
  the OpenAPI document — see [API documentation](#api-documentation).

## Resource hierarchy

```
Community  →  Collection  →  Work
                              ↓
                            FileSet
                              ↓
                             Blob
```

| Resource    | Represents                                                                |
|-------------|---------------------------------------------------------------------------|
| Community   | Top-level org unit; may nest sub-Communities.                             |
| Collection  | Holds Works; lives directly under a Community.                            |
| Work        | Bibliographic unit (article, thesis, dataset…); MODS metadata lives here. |
| FileSet     | Classified slot under a Work (e.g. `primary`, `supplemental`).            |
| Blob        | The binary bytes; supports byte-range streaming.                          |

Every resource has a NOID. `GET /resources/:id` resolves any NOID to its
typed endpoint (302 redirect to `/works/:id`, `/collections/:id`, etc.).

## Authentication

`require_auth` (`app/controllers/application_controller.rb`) resolves
`@current_user` from the bearer token before every action. Atlas accepts
**four** inbound credential shapes; endpoint authorization beyond identity is
enforced by [cancancan](https://github.com/CanCanCommunity/cancancan).

| # | Credential                  | Headers                                                          | Resolves to                                                                                                                                              |
|---|-----------------------------|------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1 | **Guest**                   | *(no `Authorization`)*                                           | The `:guest` user — read-only.                                                                                                                           |
| 2 | **System token**            | `Authorization: Bearer <system_token>` + `User: NUID <system NUID>` | The `:system` fixture **only** (SSO first-login provisioning). Missing/unknown NUID → 400; pairing the system token with any non-`:system` NUID → 401.   |
| 3 | **Devise-JWT user token**   | `Authorization: Bearer <jwt>`                                   | The real person named by the token's signed `sub`. The `User:` header is ignored on this path; `:system` / `:anonymous` are rejected (401).               |
| 4 | **Cerberus signed assertion** | `Authorization: Bearer <ES256 JWT>` (`iss == "cerberus"`)     | The real person named by the **signed** `sub`, verified against Cerberus's public keyset by `kid` (`aud=atlas`, `exp` with 30s leeway, ES256 only). The relay that replaced the retired `cerberus_token`. |

A blank bearer is the guest path; anything that matches none of the above is
**401**. Read endpoints generally fall through to guest when no valid auth is
supplied; write endpoints rely on the caller having been authorized upstream
(by Cerberus or by holding a personal JWT).

**Headers vs. signed identity.** The `User:` header is only meaningful on the
system path — there it must be `NUID <system NUID>` and resolves the `:system`
fixture. On the JWT and assertion paths, identity comes from the signed token,
and the `User:` header is ignored.

**Acting-as** (an admin operator acting with a separate attribution target)
lives **exclusively** on the Cerberus-assertion path and rides a **signed
`obo` claim** — never a `User:` or `On-Behalf-Of` header. It is admin-only (a
signed `obo` from a non-admin → 403). An `On-Behalf-Of` header is never
honored: it is overwritten by the signed claim on the assertion path, and
rejected (403) on every other path.

## Credentials reference

Atlas reads these keys from Rails encrypted credentials (`rails
credentials:edit`):

| Key                     | Purpose                                                                                                                                                                                                  |
|-------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `cerberus_signing_keys` | `{ kid => PEM }` map of Cerberus's **public** signing keys, used to verify relay assertions (ES256). Public keys only — safe at rest, nothing to rotate as a secret. Empty (the default until Cerberus is provisioned) leaves the assertion path inert. |
| `system_token`          | Shared bearer secret for the system / provisioning path (paired with Cerberus's `atlas_system_token`).                                                                                                    |
| `jwt_secret`            | devise-jwt signing secret. **Falls back to `secret_key_base`** until provisioned; rotating it is a global token kill-switch that does not also invalidate sessions/cookies.                              |
| `secret_key_base`       | Standard Rails secret.                                                                                                                                                                                    |

## API documentation

The contract is generated from request specs ([rswag](https://github.com/rswag/rswag))
and rendered two ways:

- **Humans:** [`/docs`](http://localhost:3000/docs) — interactive reference
  via [Scalar](https://scalar.com).
- **Machines** (clients, agents, codegen):
  [`/api-docs/openapi.yaml`](http://localhost:3000/api-docs/openapi.yaml).

The committed `openapi/openapi.yaml` is the source of truth. To regenerate
after editing a spec or jbuilder partial:

```bash
bin/openapi
```

CI runs the same generator and fails the build if the committed YAML
diverges from what the specs produce. Atlas's response shape lives in
`app/views/**/*.jbuilder` partials; the matching schemas live in
`spec/support/openapi_schemas.rb`. Strict schema validation in the request
specs catches drift between the two.

## Running locally

```bash
docker compose up -d        # web, db (postgres), solr
open http://localhost:3000  # API root
open http://localhost:3000/docs
```

The dev image mounts `./` into the container (`docker-compose.dev.yml`), so
edits land live. The `web` service entrypoint runs `db:create` + `db:migrate`
on boot, so a fresh checkout is one command away from a working API.

## Tests

```bash
docker compose exec web bundle exec rake          # full suite
docker compose exec web bundle exec rspec spec/requests/   # contract specs (rswag)
docker compose exec web bundle exec rspec spec/integration/   # atlas_rb client round-trips
docker compose exec web bundle exec rake rswag:specs:swaggerize   # regenerate openapi.yaml
```

There are three concentric test layers:

1. **Controller specs** (`spec/controllers/`) — fast, mock-friendly,
   per-action.
2. **Request specs** (`spec/requests/`) — rswag DSL; double as the OpenAPI
   source. Strict schema validation flags response drift.
3. **Integration specs** (`spec/integration/`) — boot a real Puma server
   via Capybara, drive Atlas through `atlas_rb` over HTTP. This is the
   end-to-end contract test against the same client Cerberus uses in
   production.

## Stack

- Ruby 3.0, Rails 7, Postgres 14, Solr (Blacklight image)
- [Valkyrie](https://github.com/samvera/valkyrie) for the metadata persistence
  abstraction; a custom Valkyrie [OCFL](https://ocfl.io) storage adapter
  (`app/lib/valkyrie/storage/ocfl.rb`) for binary storage
- [jbuilder](https://github.com/rails/jbuilder) partials per resource
  (`app/views/{resource}/_{resource}.json.jbuilder`) — single source of
  truth for response shapes
- [Devise](https://github.com/heartcombo/devise) + devise-jwt for the
  user-token path (the non-Cerberus side of auth)
- [pagy](https://github.com/ddnexus/pagy) for index-action pagination
- [rswag](https://github.com/rswag/rswag) for spec-driven OpenAPI

## License

Internal Northeastern University Libraries project — contact the maintainers
for licensing.
