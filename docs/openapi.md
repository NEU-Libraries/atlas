# The OpenAPI documents

The public OpenAPI document is Atlas's contract with every client it will ever have,
including the ones nobody has built yet. The test it must pass: a developer who
has only the published document can build a client that works.

Source files:

- `spec/support/openapi_document.rb` — each document's frame: `info`,
  security, tags, shared responses
- `spec/support/openapi_contract.rb` — the rules applied to every operation,
  with `openapi_response_texts.rb` and `openapi_schema_pruning.rb`
- `spec/support/openapi_error_bodies.rb` — which 4xx responses carry an `Error`
  body, and the hook that checks it
- `spec/support/openapi_examples.rb`, `spec/openapi_examples/` and
  `bin/openapi-record` — the recorded example bodies
- `spec/swagger_helper.rb` — the rswag configuration and the spec helpers
- `spec/support/openapi_schemas.rb` — the component schemas
- `config/initializers/rswag_api.rb` — the directory `/api-docs` serves
- `spec/requests/*_spec.rb` — the operations, through the rswag DSL
- `openapi-lint/` and `bin/openapi-lint` — the mechanical gate

## The document is generated

`bin/openapi` runs `rake rswag:specs:swaggerize` over the request specs and
writes two documents. CI regenerates both and fails when a committed file
differs. So fix a document in the specs and the support files, never in the
YAML: a hand edit is overwritten on the next regenerate.

The generator runs RSpec with `--dry-run`. No example executes and no hook
fires, so anything the documents carry must come from spec metadata or from
the formatter, never from a response a spec received.

A schema exists only where a spec author wrote one, so a shape that no spec
pins down stays loose; the rules below close the common gaps.

### What a client reads for each status

The string in `response '200', '<name>'` names a test, such as "the two filters
combine — finished but degraded". It is not what the document publishes. Each
verb block maps every status it declares to one sentence a client reads:

```ruby
post 'Create a community' do
  tags 'Communities'
  response_texts(
    '200' => 'The new Community.',
    '422' => 'The parent Community is tombstoned.'
  )
```

One sentence covers every response block that shares a status, which matters
because rswag merges them into one documented response. A 2xx says what the body
is; a 4xx says the condition that causes it. `bin/openapi` fails, naming the
operation and status, when a declared status has no sentence, so a test name is
never published. The shared `401`, `403` and `404` responses carry their own text
and need none.

## Two documents

| Document | Served | Holds |
|---|---|---|
| `openapi/public/openapi.yaml` | at `/api-docs/openapi.yaml`, rendered at `/docs` | every operation a third-party client can use |
| `openapi/internal/openapi.yaml` | never | the operator and backend operations |

An operation is internal when only the system token, the fixity token or an
admin can call it, or when it is a debug view of the Solr index. Tag one with
`openapi_spec: OpenapiDocument::INTERNAL` on its `path` or on its verb. Leaving
an operation out of the public document does not protect it: its gate must
hold on its own, and the access matrices test that it does.

**The internal document must stay outside `openapi/public`.** The Rswag
middleware serves every file under its root, so a file inside the served
directory is public whatever its name. `spec/requests/docs_spec.rb` fails if
`/api-docs` ever serves it.

## What every operation gets

`OpenapiContract.finish` runs in the formatter, on each whole document, just
before it is written:

- **An `operationId`,** named from the controller action that serves the
  route: `works#show` becomes `works_show`. When one action serves two routes,
  both take a name built from the path instead. A spec can still set its own.
- **The shared `401`,** on every operation whose security names a scheme.
  `require_auth` answers a bad credential the same way on every route, so the
  documents state it once, as the `Unauthorized` response.
  `spec/requests/openapi_contract_spec.rb` sends a bad token to every such
  operation and checks the answer.
- **The shared `503` and `304`.** Any operation can meet an outage or a
  maintenance window, so each gets `ServiceUnavailable`; every GET whose body
  is buffered carries a weak `ETag`, so each gets `NotModified`. A file's
  streamed bytes carry no `ETag`, so the two byte routes get no `304`.
- **The shared `403` and `404`.** Every action calls `authorize!`
  (`check_authorization` enforces it), so any secured operation can refuse,
  and the documents attach the `Forbidden` response to each. Every path
  parameter is a lookup, so an operation with one gets `NotFound`. The contract
  spec sends an unknown identifier to each such operation and checks the 404;
  the access matrices prove the refusals. Call `no_not_found` in the verb block
  of an operation whose path parameter is not a lookup, such as a list that is
  empty for an unknown value.
- **A description for each identity path parameter** a spec left blank, from
  `OpenapiContract::PATH_PARAMETERS`, so `id` means the same on every route.
- **Only the schemas it uses.** Both documents start from the whole map in
  `openapi_schemas.rb`, and each keeps the schemas its own operations reach.
  Otherwise the public document would publish the shapes of the operations
  it leaves out.

Each document sets its security once, at the top. The public one accepts a
bearer token or nothing, which is the guest. The internal one accepts the
system or fixity token with a `User` header, or an admin's bearer token. An
operation that skips `require_auth` declares `security []`. Do not declare
`Authorization` or `User` as a header parameter: rswag sends the header from a
`let` of the same name through the security scheme, and the gate counts a
hand-written one.

### Error bodies

Every 4xx body is the `Error` schema, with two exceptions the documents state:
a 404 or 416 has no body by default, and a 410 that declares its own schema,
such as a tombstoned resource's record, keeps it. The formatter applies that
rule to each document (`OpenapiErrorBodies`). While the request specs run, an `after` hook checks
every 4xx response a spec receives against the same rule, and fails the
example when the two disagree.

Inside a response block, `no_body` marks a 4xx that answers bare, and
`error_body` marks a 404 or 416 that carries an `Error`. When one status has
several response blocks, rswag merges them into one documented response, so
one `error_body` makes the documented response carry a body.

`Error` is closed: a key Atlas adds to an error body fails the specs until the
schema names it. Its `error` has no `enum`, because a 400, 401 or 403 puts a
sentence there, and some 422s put a sentence there with the code in `code`.

### Bodies rswag cannot describe

rswag gives one schema to every media type an operation produces. On a route
that serves XML or HTML as well as JSON, `json_schema :Name` in the response
block declares the JSON body's schema alone, and the response hook checks every
JSON body a spec receives against it. A file's bytes take `binary_body`, which
documents `*/*` with a binary schema, since Atlas serves each file's own media
type; a `schema` would make rswag parse the bytes as JSON.

The MODS JSON's object members, such as a name or a title, are read off the
AttrJson models that serialise them (`attr_json_schema`), so their schemas cannot
drift from the projection. None of a member's keys is required, because attr_json
stores only the keys a value set, and each member is closed to unknown keys.

### Paging

Declare a list's paging with `paginated`, or `paginated per_page: true` where
the action reads `per_page`. Add `shape: :search` on a list that returns
`SearchPagination`, so its `page` text gives the right stop rule. A list's
`pagination` block has one of two shapes: pagy's `Pagination`, from
`LazyPagination`, or `SearchPagination`, which `SearchQuery` and
`WorkDigestQuery` build themselves. Both read the parameters the same way, and
`spec/requests/paging_params_spec.rb` holds them to it.

## Examples

Every 2xx JSON response carries a real body as its example. The generator runs
with `--dry-run`, so the bodies cannot come from responses at generation time.
They are recorded instead, into one committed file per operation and status,
and `OpenapiContract.finish` attaches them:

```bash
bin/openapi-record          # record, then regenerate; about six minutes
```

The files sit in `spec/openapi_examples/<verb>_<path>/<status>.json`, keyed on
the path rather than the `operationId`, which is settled only once a whole
document is built. When several examples hit one operation and status, the one
with the lowest RSpec id wins, so recording unchanged code twice picks the same
body. Recording hooks into rswag's own response, before a `run_test!` block can
send another request.

Re-record after a change to a jbuilder partial, or to the fixtures a recorded
spec builds. Until then an example can lag the code. Spectral's
`oas3-valid-media-example` holds every example to its current schema, so a
change of shape fails the gate; a change of value does not.

### Every example is published

So every example must be safe to publish. The recorder scrubs each body as it
writes it: a NOID or UUID becomes a stable placeholder, the same value mapping
to the same placeholder throughout one body, and timestamps, dates (also inside
a sentence), digests, email addresses, row ids, Solr's `_version_` and the
values of `jti`, `token` and password keys become fixed values. That also makes
a re-recording of unchanged code produce no diff.

NOIDs are matched exactly, not by shape. A NOID can be nine digits, which is
also the shape of a NUID, so the recorder reads every NOID the example's
fixtures hold from the database and replaces those. NUIDs are fixture
constants and stay as they are.

One example still moves: `GET /fixity_checks/due` orders ties by object key,
which holds a NOID, and NOIDs are random on every run. Its items can reorder
when it is re-recorded.

`spec/requests/openapi_examples_spec.rb` fails if a committed example holds
anything the scrubber should have replaced, or names a host outside the
reserved example domains and `OpenapiExamples::PUBLIC_HOSTS`. Adding a host to
that list is a decision that its URLs are safe to publish. It also fails on an
example whose operation and status no longer exist.

A route that serves XML and JSON declares no schema, because rswag would give
both media types the same one. Its recorded JSON body still gets a JSON media
type to sit under.

## The gate

```bash
bin/openapi-lint             # the counts per document and rule
bin/openapi-lint --verbose   # every finding, with its path
bin/openapi-lint --check     # exit non-zero when a count differs
bin/openapi-lint --update    # write the current counts to the baseline
```

The gate runs on the host with Node, not in the web container. The first run
installs the pinned tools from `openapi-lint/package-lock.json`. It checks
every `.yaml` file under `openapi/`, in two parts:

1. **Spectral**, with `openapi-lint/spectral.yaml`.
2. **A generated client.** `openapi-typescript` turns the document into
   TypeScript types, and `tsc --strict` must compile them. Each compiler error
   counts once, as `client-typescript`.

### What counts

A finding counts when it makes the document invalid, breaks a generated
client, or breaks a contract that Atlas already states in prose. The counted
rules are the ones marked `error` in `spectral.yaml`:

| Rule | Why it counts |
|---|---|
| `oas3-schema`, `no-$ref-siblings`, `typed-enum`, `path-params` | An invalid document, or one that tools read differently |
| `oas3-valid-schema-example`, `oas3-valid-media-example` | An example that contradicts its own schema misleads more than no example |
| `operation-operationId`, `operation-operationId-unique` | A generated client names its methods from these |
| `atlas-4xx-uses-error-schema` | A client branches on `error` for any failure ([`error-contract.md`](error-contract.md)) |
| `atlas-secured-operation-documents-401` | A bad credential is a `401` on every operation that takes one |
| `atlas-no-authorization-parameter` | A hand-written `Authorization` parameter duplicates the security scheme, so a generated client asks for the token twice |
| `atlas-2xx-json-has-example` | A stranger learns a response faster from one real body than from its schema |
| `client-typescript` | A client that does not compile is no client |

Every other `spectral:oas` rule is a warning. The gate reports it and never
counts it: `info-contact`, `operation-description`, `openapi-tags-alphabetical`
and the like are matters of taste.

`atlas-4xx-uses-error-schema` checks only a 4xx that declares a body. Atlas
answers some 404s with no body, and the rule must not demand one. A 4xx that
does have a body but whose spec declared none passes the rule, so the rule
alone cannot prove the error contract.

### The baseline is a ratchet

`openapi-lint/baseline.json` holds the count for each document and rule.
`--check` fails when any count differs from it, in either direction:

- **A count that rose** is a new fault. Fix it, or accept it with `--update`
  and say why in the commit message.
- **A count that fell** is a fix. Record it with `--update` in the same
  commit, so the next regression cannot hide under the old, higher number.

CI runs `bin/openapi-lint --check` after it regenerates the documents, and
`bin/openapi` runs it too, so a fault shows when you regenerate rather than on
the build.

### Before a commit

A git hook can run the gate before any commit that touches what the documents
are built from. Hooks are per developer and stay out of the repository, so
install it yourself as `.git/hooks/pre-commit` (which every worktree shares) and
make it executable:

```bash
#!/usr/bin/env bash
set -uo pipefail
root="$(git rev-parse --show-toplevel)"
git diff --cached --name-only |
  grep -qE '^(openapi/|openapi-lint/|spec/requests/|spec/support/openapi|spec/swagger_helper\.rb|spec/openapi_examples/|app/views/.*\.jbuilder$)' || exit 0
[[ -x "$root/bin/openapi-lint" ]] || exit 0           # a branch from before the gate
command -v node >/dev/null 2>&1 || exit 0              # no Node, no gate
"$root/bin/openapi-lint" --check || {
  echo 'OpenAPI gate failed: run bin/openapi, then fix or --update the baseline.' >&2
  exit 1
}
```

It checks the documents as they are in the working tree, so run `bin/openapi`
first when you changed a request spec or a partial. `git commit --no-verify`
skips it once.
