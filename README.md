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
                                      │  Bearer <system token>
                                      │  User: NUID <nuid>
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
  requests to Atlas with a pre-shared system bearer token plus a `User:
  NUID <nuid>` header naming the acting user.
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

Two headers, both threaded through from Cerberus:

| Header          | Form                          | Purpose                                                                   |
|-----------------|-------------------------------|---------------------------------------------------------------------------|
| `Authorization` | `Bearer <token>`              | Cerberus system token *or* a devise-jwt user token. Both are accepted.    |
| `User`          | `NUID <nuid>`                 | When the bearer is the system token, names the user being acted on behalf of. |

Read endpoints generally fall through to a guest user when no valid auth is
supplied. Write endpoints rely on Cerberus having already authorized the
caller. See `app/controllers/application_controller.rb` for the resolution
order.

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
  abstraction; [Shrine](https://github.com/shrinerb/shrine) for binary storage
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
