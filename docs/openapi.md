# The OpenAPI document

The OpenAPI document is Atlas's contract with every client it will ever have,
including the ones nobody has built yet. The test it must pass: a developer who
has only the published document can build a client that works.

Source files:

- `spec/swagger_helper.rb` — the document's frame: `info`, security, tags,
  shared responses
- `spec/support/openapi_schemas.rb` — the component schemas
- `spec/requests/*_spec.rb` — the operations, through the rswag DSL
- `openapi-lint/` and `bin/openapi-lint` — the mechanical gate

## The document is generated

`bin/openapi` runs `rake rswag:specs:swaggerize` over the request specs and
writes `openapi/openapi.yaml`. CI regenerates it and fails when the committed
file differs. So fix the document in the specs and in `swagger_helper.rb`,
never in the YAML: a hand edit is overwritten on the next regenerate.

The same design explains the document's typical faults. The string in
`response '200', '<text>'` is both the example group's name and the published
description, so a scenario name such as "the two filters combine" becomes what
a client author reads. And a schema exists only where a spec author wrote one,
so a shape that no spec pins down stays loose.

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

CI runs `bin/openapi-lint --check` after it regenerates the document.
