# The error contract

Every failure Atlas renders has a shape, and `atlas_rb` keys on it to raise a
typed error. That makes the shape a wire contract rather than a presentation
detail.

Source files:

- `app/controllers/application_controller.rb` — the `rescue_from` handlers
- `app/controllers/concerns/backend_unavailable.rb` — the dependency-outage handlers
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

Three codes are exact-match strings that `atlas_rb` depends on. Do not change
any of them without a contract bump:

| Code | Status | `atlas_rb` raises |
|---|---|---|
| `stale_resource` | 409 | `AtlasRb::StaleResourceError` |
| `read_only_mode` | 503 | `AtlasRb::ReadOnlyModeError` |
| `backend_unavailable` | 503 | `AtlasRb::BackendUnavailableError` |

## The handlers

| Exception | Status | `error` value | Raised when |
|---|---|---|---|
| `CanCan::AccessDenied` | 403 | The message, plus `action` and `subject` | An ability denial |
| `ActiveRecord::RecordInvalid` | 422 | `invalid_record` | An AR-tier validation failure |
| `ActiveRecord::RecordNotFound` | 404 | *(bare 404, no body)* | An AR-tier `find_by!` miss |
| `Valkyrie::StorageAdapter::FileNotFound` | 404 | *(bare 404, no body)* | A stored file is missing from a root that has its marker; also when a view raised it, such as a MODS XML read |
| `Valkyrie::Persistence::StaleObjectError` | 409 | `stale_resource` | An optimistic-lock conflict |
| `Exceptions::ReparentError` | 422 | The exception's code | Bad parent type, a cycle, a tombstoned node or parent, a missing or unresolvable parent |
| `Exceptions::LinkedMemberError` | 422 | The exception's code | Target missing, not a Collection, tombstoned; the Work tombstoned; already a structural member |
| `Exceptions::WorkAssociationError` | 422 | The exception's code | Unknown type; target missing, not a Work, or the Work itself; either end tombstoned |
| `Exceptions::FixityMismatch` | 422 | The exception's code | Uploaded bytes do not match `expected_digest`, or an unsupported digest algorithm |
| `Exceptions::BlobMetadataError` | 422 | The exception's code | A Blob's `language` is not shaped like a BCP 47 tag, or its `track_label` is over 64 characters |
| `Exceptions::DarwinCoreError` | 422 | The exception's code | A Darwin Core upload is not well-formed (`malformed_xml`), has the wrong root (`invalid_root`), holds other than one record (`record_count`) or repeats a term (`duplicate_term`) |
| `Exceptions::DerivativePermissionsError` | 422 | The exception's code | Unknown tier, a tier more visible than its Work, or visibility not narrowing with resolution |
| `Exceptions::PreviewImageError` | 422 | The exception's code | The preview's size or placeholder is malformed (`invalid_preview_dimension`, `invalid_preview_placeholder`), half a size (`preview_dimensions_incomplete`), or sent without the preview URI (`preview_required`) |
| `Exceptions::PermissionsError` | 422 | The exception's code | An ACL write breaking a rights invariant — today, a read audience wider than the structural parent's |
| `Exceptions::ReadOnlyMode` | 503 | `read_only_mode` | A write reached Atlas during a maintenance window |
| `ActiveRecord::ConnectionNotEstablished`, `ActiveRecord::ConnectionFailed` | 503 | `backend_unavailable`, `dependency: "database"` | Postgres refused, dropped or timed out a connection |
| `RSolr::Error::ConnectionRefused`, `RSolr::Error::Http` with a 5xx or a timeout | 503 | `backend_unavailable`, `dependency: "index"` | Solr is down, overloaded or loading its core |
| `Valkyrie::Storage::OCFL::StorageUnavailable`, and the filesystem faults listed below | 503 | `backend_unavailable`, `dependency: "storage"` | An id names a storage root with no OCFL marker, or the filesystem failed |

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

## Why a dependency outage is a 503 and not a 500

A 500 is as likely to be a bug as an outage, so a client cannot show a
"temporarily unavailable" page for one without lying about half of them. The
`backend_unavailable` body names which dependency failed:

```json
{ "error": "backend_unavailable", "dependency": "storage", "message": "…" }
```

**The body names the dependency and nothing more.** The handler can fire before
`require_auth` has resolved a principal, because resolving even the guest reads
the database. So host names and the exception text go to the log at `error`
level, never to the wire. `Retry-After` is a fixed 30 seconds, because an outage
has no scheduled end the way a maintenance window does.

The handlers live in a concern so `ApplicationController` keeps the auth logic.
Controllers that include `IndexReadGate` declare their own Solr handler, which
Rails consults first, so the operator inspection endpoints keep their `502
solr_unavailable` (see [`solr-indexing.md`](solr-indexing.md)).

### What counts as an outage

| Dependency | Counts | Does not count |
|---|---|---|
| `database` | `ConnectionNotEstablished` and its subclasses, which include a pool checkout timeout; `ConnectionFailed`, a connection lost mid-query | A query error, a validation failure |
| `index` | A refused connection, a timeout, a 5xx from Solr | A 4xx from Solr. Atlas built that query, so it stays a 500 |
| `storage` | `StorageUnavailable`; `EIO`, `EROFS`, `ENOSPC`, `EDQUOT`, `ESTALE`, `ENOTCONN`, `EHOSTDOWN` | `ENOENT` and `EACCES`, each as likely to be a wrong path in Atlas's code |

`ENOTCONN` and `ESTALE` are the faults a network mount raises when it drops,
which is how SMB or NFS storage fails in practice.

### The cache is not on the list

Redis errors never reach a controller. The cache store's `error_handler`
(`config/cache_store.rb`) treats a failed read as a miss and renders, so a Redis
outage makes reads slower and nothing else. `GET /health` still reports it.

The one exception is `GET /metrics/latency`, whose figures live in Redis. Its
controller answers `backend_unavailable` with `dependency: "cache"` itself (see
[`read-performance.md`](read-performance.md)).

### `StorageUnavailable` and the missing volume

**Every root that holds an object carries the OCFL marker file `0=ocfl_1.1`**,
because the adapter writes it before the first object. So when a read names a
root without the marker, that root is lost or did not mount. The adapter raises
`StorageUnavailable` rather than `FileNotFound`, which would answer 404 and
report the content as never deposited. A missing object inside a root that has
the marker is still a `FileNotFound`.

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
