# Authentication

How Atlas decides *who* is calling. What that principal may then do is
[`authorization.md`](authorization.md); the error shapes every failure renders
are [`error-contract.md`](error-contract.md).

Source file: `app/controllers/application_controller.rb`.

Atlas never takes a password. The devise `sessions` and `registrations` routes
are skipped, and human authentication is delegated to Cerberus SSO. The devise
modules stay on `User` so the `:user` warden mapping the JWT decoder needs is
preserved, and for any future non-SSO service account.

## Three bearer credentials, plus the blank case

`require_auth` runs before every action and resolves `@current_user` from the
`Authorization: Bearer` header. It dispatches in a fixed order: blank, then
system token, then Cerberus assertion, then devise-jwt.

| Credential | Identity comes from | Who holds it |
|---|---|---|
| Blank token | The `:guest` fixture | Anonymous callers; reads generally fall through here |
| `system_token` | The `User: NUID` header, which must name `:system` | Cerberus, backend to backend |
| Cerberus signed assertion | The proven `sub` claim | Cerberus, relaying a person after SSO |
| devise-jwt | The token's `sub` | A librarian's script, calling the API directly |

Anything else is a 401.

### The blank case

A real `User` row with the `:guest` role and no permissions, not a nil user.
Writes are expected to have been authorized upstream by Cerberus.

### `system_token`

A shared secret in `credentials.system_token`, paired with a `User: NUID` header.
The pairing is a rule, not a convenience: the header must resolve to the
`:system` fixture, and a token presented with any other NUID is a 401.

**The pairing closes the leaked-token footgun.** A stolen system token cannot
impersonate a real person, because the only principal it can resolve is
`:system`.

### The Cerberus signed assertion — the relay

A short-lived JWT that Cerberus signs with its *private* key. Atlas verifies it
against Cerberus's public keyset in `credentials.cerberus_signing_keys`, keyed
`kid → PEM`. Public keys only, so the credential is safe at rest and there is
nothing to rotate as a secret. An empty keyset — the default until Cerberus is
provisioned — leaves the whole path inert.

Verification is strict:

- **ES256 is pinned.** Never HS256, which would open the
  public-key-as-HMAC-secret algorithm-confusion attack, and never `none`.
- The signing key is selected by the assertion's `kid`. An unknown `kid` fails.
- `iss` must be `cerberus`, `aud` must be `atlas`, and `exp` is enforced with 30
  seconds of leeway for clock skew.

Routing to this path is a deliberate two-step. `cerberus_assertion?` reads `iss`
**without verifying**, because you cannot know which issuer or key applies until
you look. The trust decision is made separately and strictly in
`resolve_cerberus_assertion`. Once the peek matches, a verification failure is a
hard reject with no fall-through: the caller declared itself a Cerberus
assertion, so it does not get a second chance as something else.

Identity is the signed `sub`. The `User:` header is not consulted on this path.

**The optional `acct` claim picks an account.** One NUID can hold several
accounts, because staff and student logins share it. A signed `acct` (an email)
names which one is acting, and that account's stored group set drives
authorization. Absent the claim, the person's preferred account is used. `sub`
stays the NUID, the thread that groups the accounts, and the selector is
additive. An `acct` that is not one of this NUID's accounts is a 400, mirroring
the unknown-principal case.

### devise-jwt — the standalone API path

Minted by `POST /nuid`, which is system-gated and called by Cerberus after SSO,
then used directly as `Authorization: Bearer <jwt>`. A one-week TTL.

`resolve_jwt_user` routes through the warden `:jwt` strategy rather than
hand-decoding, and that choice does real work: the strategy runs `TokenDecoder`
for signature and `exp` **and** the JTIMatcher revocation check, converting every
`JWT::DecodeError` subclass into a clean `fail!`. So the method returns nil,
never an exception, for an expired, revoked, malformed, nil-user or wrong-scope
token.

The `User: NUID` header is ignored. Identity lives in the token's `sub`.

**The non-human bookends are rejected here even so.** `:system` and `:anonymous`
must never be reachable through a personal token. Minting is already gated to
real persons, but this is the wire backstop. Together with the system-token
pairing rule, this is the other half of the leaked-token property: a personal JWT
cannot reach `:system`, and a system token cannot reach a person.

## Acting as another person

Acting-as attributes a write to a target NUID while a different operator
authorizes it. The operator's rights decide the request; the target is only an
attribution stamp and needs no rights of its own. Downstream, both the
two-principal `AuditEvent` and the rule that nulls `proxy_uploader` under
impersonation hang off `@on_behalf_of`.

**It rides a signed `obo` claim, never a header.** On the assertion path,
`resolve_cerberus_assertion` sets `@on_behalf_of` from the verified payload,
**overwriting** whatever `parse_headers` read. So an attacker cannot append an
`On-Behalf-Of` header to a stolen assertion to forge acting-as: absent an `obo`
claim, the value resolves to nil.

`parse_headers` reads the `On-Behalf-Of` header at all only so the gate can
reject it.

`enforce_on_behalf_of_gate` allows exactly two cases:

1. **An admin operator on the assertion path.** `@auth_source` is `:assertion`
   only for the signed-claim path, so a stray header on the JWT-direct or guest
   path is a 403 even for an admin. Those paths have no operator/target split to
   appeal to.
2. **`:system`.** Trusted through a plain header rather than a signed claim,
   because the system-token path is a backend-to-backend credential only Cerberus
   holds and never a human. A caller who can present it is already as trusted as
   the `User: NUID` header on that same path. The NUID carried here is what
   scopes `:system`'s `:link_member` grant to the depositor's own Work — see
   [`authorization.md`](authorization.md).

Everything else with a present `On-Behalf-Of` is a 403.

## The resolution matrix

| Request | Result |
|---|---|
| Blank token | `:guest`, read-only |
| `system_token`, `User` header missing | 400 |
| `system_token`, unknown NUID | 400 |
| `system_token`, non-`:system` NUID | 401 (pairing rule) |
| `system_token`, `:system` NUID | `:system` |
| Valid JWT for a real person | That user; header ignored |
| JWT naming `:system` or `:anonymous` | 401 (bookend guard) |
| Expired, revoked or malformed JWT | 401 |
| Assertion with a real-person `sub` | That user, from `sub` |
| Assertion with a bad signature, `kid`, `aud` or `exp` | 401 |
| Assertion naming `:system` or `:anonymous` | 401 |
| Assertion with an unknown `sub` | 400 |
| Assertion with an unknown `acct` for a known `sub` | 400 |
| Assertion plus signed `obo`, admin `sub` | Operator, acting as the target |
| Assertion plus signed `obo`, non-admin `sub` | 403 |
| `system_token` plus `On-Behalf-Of` header | Trusted; showcase-publishing attribution |
| `On-Behalf-Of` header on any other path | 403 |
| Any other token | 401 |

## Two write floors in `authorize!`

`ApplicationController` overrides cancancan's `authorize!` to layer two floors in
front of the real ability check. Both are deliberately outside `Ability`, so no
grant — present or future — can bypass them.

Both answer the same question, "is this action read-shaped?", from one allowlist:

```ruby
READ_ONLY_TOKEN_ACTIONS = %i[read read_directory read_versions index_all preview].freeze
```

**One allowlist is the point.** A write-shaped action added next year is refused
by default and need not be enumerated anywhere.

### The per-token floor

A JWT minted with the `read_only` custom claim sets `@token_read_only`, and any
action outside the allowlist raises `CanCan::AccessDenied`. Raising the same
exception a normal denial would means it composes with the existing `rescue_from`
and with `check_authorization`, so there is no separate rescue path.

`resolve_jwt_user` re-decodes the token to read the claim. That is safe: the
warden call immediately above already verified signature, revocation and expiry
through this same `TokenDecoder`, so this only reads a claim off a token already
proven authentic.

### The repository-wide floor

`repository_read_only?` raises `Exceptions::ReadOnlyMode` during a maintenance
window. Nothing is exempted, `GET /reset` included, whose `RESETTABLE_ENVS` guard
is a separate concern. See [`availability.md`](availability.md).

`read_only_exempt?` returns `false` here and is overridden only by
`PUT /maintenance`, which is what keeps the window closable. Everything else is
refused, which is the fail-closed property the floor exists for.

## Strict authorization

`check_authorization unless: :public_endpoint?` raises
`CanCan::AuthorizationNotPerformed` when an action forgets to call `authorize!`,
so a new endpoint without a gate fails its first test rather than shipping open.

`public_endpoint?` returns `false` — nothing skips authorization today.
`DocsController` inherits `ActionController::Base` and is already exempt by
class. The hook is kept as the escape hatch for a future health-check or metrics
endpoint.

## `current_ability` and `readable`

cancancan looks up `current_user` to build the `Ability`. Atlas's shape is a
bearer token plus headers, which sets `@current_user`, so `current_ability`
overrides the helper to source from it and passes `@on_behalf_of` through.

`readable(resources)` drops the rows a caller may not read. **Any endpoint
returning a list has to apply the read gate per row**, or it hands back exactly
what the gate on the single-resource route refuses. It is used by the `/children`
listings and the batch resolver, whose contracts already allow a short result,
so a filtered row is indistinguishable from an absent one.
