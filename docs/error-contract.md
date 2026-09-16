# The error contract

Every failure Atlas renders has a shape, and `atlas_rb` keys on it to raise a
typed error. That makes the shape a wire contract rather than a presentation
detail.

Source files:

- `app/controllers/application_controller.rb` — the `rescue_from` handlers
- `app/lib/exceptions/*.rb` — the exception classes and their codes

Response *bodies* for successful reads are not documented here. They live in the
jbuilder partials and the generated `openapi/openapi.yaml`.

## The discriminator is `error`

Most handlers render the same three-key body:

```json
{ "error": "<machine code>", "resource_id": "<noid>", "message": "<human detail>" }
```

`error` carries a machine-readable code and `message` carries the detail a person
reads. **A client branches on `error` and never parses `message`.**

Two codes are exact-match strings that `atlas_rb` depends on. Do not change
either without a contract bump:

| Code | Status | `atlas_rb` raises |
|---|---|---|
| `stale_resource` | 409 | `AtlasRb::StaleResourceError` |
| `read_only_mode` | 503 | `AtlasRb::ReadOnlyModeError` |

## The handlers

| Exception | Status | `error` value | Raised when |
|---|---|---|---|
| `CanCan::AccessDenied` | 403 | The message, plus `action` and `subject` | An ability denial |
| `ActiveRecord::RecordInvalid` | 422 | `invalid_record` | An AR-tier validation failure |
| `ActiveRecord::RecordNotFound` | 404 | *(bare 404, no body)* | An AR-tier `find_by!` miss |
| `Valkyrie::Persistence::StaleObjectError` | 409 | `stale_resource` | An optimistic-lock conflict |
| `Exceptions::ReparentError` | 422 | The exception's code | Bad parent type, a cycle, a tombstoned node or parent, a missing or unresolvable parent |
| `Exceptions::LinkedMemberError` | 422 | The exception's code | Target missing, not a Collection, tombstoned; the Work tombstoned; already a structural member |
| `Exceptions::WorkAssociationError` | 422 | The exception's code | Unknown type; target missing, not a Work, or the Work itself; either end tombstoned |
| `Exceptions::FixityMismatch` | 422 | The exception's code | Uploaded bytes do not match `expected_digest`, or an unsupported digest algorithm |
| `Exceptions::DerivativePermissionsError` | 422 | The exception's code | Unknown tier, a tier more visible than its Work, or visibility not narrowing with resolution |
| `Exceptions::PermissionsError` | 422 | The exception's code | An ACL write breaking a rights invariant — today, a read audience wider than the structural parent's |
| `Exceptions::ReadOnlyMode` | 503 | `read_only_mode` | A write reached Atlas during a maintenance window |

Every 422 above rejects before anything persists, so a failed request leaves
nothing behind.

## Why the 403 carries ability metadata

The `CanCan::AccessDenied` handler adds `action` and `subject` to the body, with
`subject` normalized to a class name whether the denial named a class or an
instance. A caller can branch on which verb was refused rather than parsing
prose.

## Why maintenance is a 503 and not a 403

A 403 says the caller lacks rights. During a migration window that is a lie: the
caller's rights are fine and the repository is closed. The handler also sets
`Retry-After` from `MaintenanceMode.retry_after`, which a 403 has no business
carrying. See [`availability.md`](availability.md).

## The 404 asymmetry

`ActiveRecord::RecordNotFound` renders a **bare** 404 with no body, matching the
`head(:not_found)` the Valkyrie controllers render for an unknown NOID. The two
tiers therefore answer a miss identically, and a client does not need to know
which store backed the lookup.

## Optimistic-lock conflicts reach the 409 two ways

Both populations render the same body, and a client cannot tell them apart —
deliberately, because the remedy is the same:

1. **Retry-safe actions** whose internal `StaleObjectRetry` budget ran out.
2. **Retry-unsafe actions** — generic update, tombstone, restore, permission
   removals — which surface the conflict immediately rather than risk clobbering
   a concurrent caller's intent.

The handler logs the controller, action and id at `warn` before rendering, since
a 409 usually means two writers met and that is worth seeing in aggregate.
