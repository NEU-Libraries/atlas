# frozen_string_literal: true

class ApplicationController < ActionController::API
  include ActionController::MimeResponds
  include CanCan::ControllerAdditions
  respond_to :json

  # Cerberus-signed relay assertion: Cerberus signs a short-lived JWT with its
  # private key; Atlas verifies with the matching public key. `iss`/`aud` bind
  # the assertion to this exchange.
  CERBERUS_ISSUER   = 'cerberus'
  CERBERUS_AUDIENCE = 'atlas'

  # The only CanCan actions a `read_only`-scoped personal JWT (see
  # Users::TokensController#nuid) may ever reach — a fail-closed floor
  # beneath the resolved user's real Ability, checked in #authorize! below.
  # A new write-shaped action added anywhere is blocked by default; it need
  # not be enumerated here.
  READ_ONLY_TOKEN_ACTIONS = %i[read preview read_versions].freeze

  before_action :require_auth

  # Strict mode: any controller action that forgets to call `authorize!`
  # raises CanCan::AuthorizationNotPerformed. This makes the
  # "remember to guard every new write action" footgun structurally
  # impossible — adding a new endpoint without authorize! fails its first
  # test.
  check_authorization unless: :public_endpoint?

  # Structured 403 for ability denials. The shape carries the ability
  # metadata (action/subject) so callers can branch on it if needed.
  rescue_from CanCan::AccessDenied do |exception|
    render json: {
      error:   exception.message,
      action:  exception.action,
      subject: exception.subject.is_a?(Class) ? exception.subject.name : exception.subject.class.name
    }, status: :forbidden
  end

  # AR-tier records (Compilation et al.): validation failures surface as a
  # uniform 422; find_by!-style lookups as a bare 404, matching the
  # head(:not_found) the Valkyrie controllers render for unknown noids.
  rescue_from ActiveRecord::RecordInvalid do |exception|
    render json: {
      error:   'invalid_record',
      message: exception.message
    }, status: :unprocessable_entity
  end

  rescue_from ActiveRecord::RecordNotFound do
    head :not_found
  end

  # Structured 409 for optimistic-lock conflicts. Two populations reach
  # here: retry-safe actions whose internal StaleObjectRetry budget
  # exhausted, and retry-unsafe actions (generic update, tombstone,
  # restore, permission removals) that surface the conflict immediately
  # rather than risk clobbering a concurrent caller's intent. The
  # `error: "stale_resource"` discriminator is the wire contract atlas_rb
  # keys on to raise its typed AtlasRb::StaleResourceError — exact-match
  # string, stable across versions, do not change without a contract bump.
  rescue_from Valkyrie::Persistence::StaleObjectError do |exception|
    Rails.logger.warn(
      'StaleObjectError surfaced as 409 on ' \
      "#{controller_name}##{action_name} id=#{params[:id]}: #{exception.message}"
    )
    render json: {
      error:       'stale_resource',
      resource_id: params[:id],
      action:      action_name,
      message:     exception.message
    }, status: :conflict
  end

  # Structured 422 for re-parent validation failures (bad parent type, cycle,
  # tombstoned node/parent, missing required parent, unresolvable parent). The
  # `error` carries Reparenter's machine-readable code so atlas_rb can raise a
  # typed error; `message` is the human-readable detail.
  rescue_from Exceptions::ReparentError do |exception|
    render json: {
      error:       exception.code,
      resource_id: params[:id],
      message:     exception.message
    }, status: :unprocessable_entity
  end

  # Structured 422 for linked-membership validation failures (target not
  # found / not a Collection / tombstoned, work tombstoned, already a
  # structural member). Same code-as-discriminator contract as the re-parent
  # path above.
  rescue_from Exceptions::LinkedMemberError do |exception|
    render json: {
      error:       exception.code,
      resource_id: params[:id],
      message:     exception.message
    }, status: :unprocessable_entity
  end

  # Structured 422 for Work-association validation failures (unknown type,
  # target not found / not a Work / the Work itself, either end tombstoned).
  # Same code-as-discriminator contract as the linked-member path above.
  rescue_from Exceptions::WorkAssociationError do |exception|
    render json: {
      error:       exception.code,
      resource_id: params[:id],
      message:     exception.message
    }, status: :unprocessable_entity
  end

  # Structured 422 for verify-on-ingest failures (an upload whose bytes don't
  # match a supplied expected_digest, or an unsupported digest algorithm).
  # Same code-as-discriminator contract; the upload is rejected before any
  # resource is persisted, so nothing is left behind.
  rescue_from Exceptions::FixityMismatch do |exception|
    render json: {
      error:       exception.code,
      resource_id: params[:id],
      message:     exception.message
    }, status: :unprocessable_entity
  end

  # Structured 422 for an invalid per-tier derivative-visibility policy (unknown
  # tier, a tier more visible than its Work, or visibility not narrowing with
  # resolution). Same code-as-discriminator contract; the policy is rejected
  # before it persists.
  rescue_from Exceptions::DerivativePermissionsError do |exception|
    render json: {
      error:       exception.code,
      resource_id: params[:id],
      message:     exception.message
    }, status: :unprocessable_entity
  end

  # Structured 422 for an ACL write that breaks a rights invariant — today a
  # read audience wider than the structural parent's. Same
  # code-as-discriminator contract; nothing is persisted.
  rescue_from Exceptions::PermissionsError do |exception|
    render json: {
      error:       exception.code,
      resource_id: params[:id],
      message:     exception.message
    }, status: :unprocessable_entity
  end

  private

    # CanCan looks up `current_user` to construct the Ability. Atlas's
    # auth shape is Bearer + NUID header (require_auth above) which sets
    # @current_user; override the CanCan helper to source from it.
    def current_ability
      @current_ability ||= Ability.new(@current_user, on_behalf_of: @on_behalf_of)
    end

    # Read-only token floor: raises the same CanCan::AccessDenied a normal
    # Ability denial would, so it composes with the rescue_from above and
    # with check_authorization's forgotten-authorize! guard — no separate
    # rescue path. Layered in front of the real check rather than inside
    # Ability so it can't be bypassed by any grant, present or future.
    def authorize!(action, subject, *args)
      if @token_read_only && READ_ONLY_TOKEN_ACTIONS.exclude?(action)
        raise CanCan::AccessDenied.new('read-only token cannot perform this action', action, subject)
      end

      super
    end

    # Endpoints that legitimately skip authorization. None today —
    # `DocsController` inherits ActionController::Base so it's already
    # exempt by class. Kept as the escape hatch for any future
    # health-check / metrics endpoint that wants to opt out.
    def public_endpoint?
      false
    end

    def parse_headers
      token_pattern = /^Bearer /
      token_header  = request.headers['Authorization']
      @token = token_header.gsub(token_pattern, '') if token_header&.match(token_pattern)

      nuid_pattern = /^NUID /
      nuid_header  = request.headers['User']
      @nuid = nuid_header.gsub(nuid_pattern, '') if nuid_header&.match(nuid_pattern)

      # An `On-Behalf-Of: NUID <nuid>` header is parsed here only so the gate
      # below can reject it: acting-as is NOT header-driven. On the assertion
      # path @on_behalf_of is overwritten by the signed `obo` claim; on every
      # other path a present header is a 403 (see enforce_on_behalf_of_gate).
      obo_header = request.headers['On-Behalf-Of']
      @on_behalf_of = obo_header.gsub(nuid_pattern, '') if obo_header&.match(nuid_pattern)
    end

    # Resolve @current_user from the bearer token.
    #
    # Three bearer credentials are recognized:
    #
    #   system_token    — atlas_rb's System namespace token. Pairs with the
    #                     `User: NUID` header, only for the :system fixture.
    #   devise-jwt      — a JWT minted for a real person by POST /nuid (the
    #                     Cerberus-delegated, standalone-API path). Identity
    #                     comes from the TOKEN, not the header; the JTIMatcher
    #                     revocation + expiry checks run inside the warden
    #                     :jwt strategy. Never resolves :system/:anonymous.
    #   cerberus assert — a short-lived JWT signed by Cerberus's PRIVATE key
    #                     (iss=cerberus, aud=atlas), verified against Cerberus's
    #                     public keyset. The relay: identity is PROVEN (`sub`),
    #                     not an asserted header; acting-as rides a signed `obo`
    #                     claim. Routed by an unverified iss peek; verification
    #                     is strict (ES256, kid-selected public key, iss/aud/exp).
    #
    # Matrix:
    #
    #   blank token                          → guest (read-only)
    #   system_token + User missing          → 400
    #   system_token + unknown NUID          → 400
    #   system_token + non-:system NUID      → 401 (pairing rule)
    #   system_token + :system NUID          → :system
    #   valid JWT (real person)              → that user (header ignored)
    #   JWT for :system / :anonymous         → 401 (bookend guard)
    #   expired / revoked / malformed JWT    → 401
    #   cerberus assertion (real-person sub) → that user (sub, not header)
    #   cerberus assertion bad sig/kid/aud/exp → 401
    #   cerberus assertion for :system/:anon → 401 ; unknown sub → 400
    #   assertion + signed `obo`, admin sub  → operator, acting as obo target
    #   assertion + signed `obo`, non-admin  → 403
    #   system_token + On-Behalf-Of header   → trusted (showcase-publishing attribution)
    #   On-Behalf-Of *header* (any other path) → 403
    #   any other token                      → 401
    #
    # The system/JWT split closes the leaked-token footgun: a stolen system
    # token can't impersonate a real person, and a personal JWT can't reach
    # :system/:anonymous. Acting-as exists only on the assertion path, via a
    # signed `obo` claim (admin-only) — never a forgeable header.
    def require_auth
      parse_headers

      if @token.blank?
        guest_sign_in
      elsif valid_system_token?
        resolve_system_user
      elsif cerberus_assertion?
        resolve_cerberus_assertion
      elsif resolve_jwt_user
        # @current_user is set inside resolve_jwt_user — identity is in the token
      else
        return render_error(:unauthorized, 'invalid bearer token')
      end

      # Runs only if a principal was resolved (the branches above bail with a
      # rendered error otherwise; `performed?` guards against a double render).
      enforce_on_behalf_of_gate unless performed?
    end

    # Acting-as authorization: the operator authorizes the request, the target
    # is only an attribution stamp and needs no rights — so HUMAN acting-as is
    # restricted to admin operators, and only on the assertion path.
    # The proxy_uploader-null-under-impersonation rule and the two-principal
    # AuditEvent both hang off @on_behalf_of downstream.
    #
    # Acting-as rides a SIGNED `obo` claim: the target is inside the signature,
    # so it can't be forged onto a stolen assertion (resolve_cerberus_assertion
    # sources @on_behalf_of from the verified claim only, never a header). The
    # JWT-direct and guest paths have no operator/target split, so a stray
    # `On-Behalf-Of` header is rejected there even for an admin — @auth_source
    # is :assertion only for the signed-claim path.
    #
    # :system is the other exception, trusted via a plain header rather than a
    # signed claim: the system_token path is a backend-to-backend credential
    # that only Cerberus holds (never a human), so a caller who can present it
    # is already as trusted as the `User: NUID` header on that same path — see
    # resolve_system_user. The on_behalf_of NUID carried here is what scopes
    # :system's `:link_member` grant (Ability) to the depositor's own Work.
    def enforce_on_behalf_of_gate
      return if @on_behalf_of.blank?
      return if @current_user&.admin? && @auth_source == :assertion
      return if @current_user&.system?

      render_error(:forbidden, 'On-Behalf-Of requires an admin operator')
    end

    def resolve_system_user
      return render_error(:bad_request, 'User: NUID header required') if @nuid.blank?

      user = User.find_by(nuid: @nuid)
      return render_error(:bad_request, "unknown principal #{@nuid}") if user.nil?

      unless user.system?
        return render_error(:unauthorized,
                            'system token must only be paired with the :system fixture')
      end

      @current_user = user
    end

    # Resolve a real person from a devise-jwt bearer token via the warden :jwt
    # strategy. Routing through warden (rather than hand-decoding) is deliberate:
    # the strategy runs TokenDecoder (signature + exp) AND the JTIMatcher
    # revocation check, raising JWT::DecodeError subclasses that the strategy
    # converts to a clean `fail!` — so this returns nil (not an exception) for
    # expired, revoked, malformed, nil-user, or wrong-scope tokens. The
    # `User: NUID` header is ignored; identity lives in the token's `sub`.
    #
    # The :system/:anonymous bookends are non-human and must never be reachable
    # via a personal token, so they are rejected even if a token somehow encodes
    # them (mint is gated to real persons, but this is the wire backstop).
    #
    # A token minted with the `read_only` custom claim (see
    # Users::TokensController#nuid) sets @token_read_only, which #authorize!
    # below uses to allowlist a handful of read-shaped actions and reject
    # everything else — a structural write-floor independent of whatever the
    # resolved user's own Ability grants. Re-decoding here is safe: the
    # warden call above already verified signature + revocation + expiry via
    # this same TokenDecoder, so this is just reading a claim off a token
    # already proven authentic.
    def resolve_jwt_user
      user = request.env['warden']&.authenticate(:jwt, scope: :user)
      return if user.nil? || user.system? || user.anonymous?

      @current_user = user
      payload = Warden::JWTAuth::TokenDecoder.new.call(@token)
      @token_read_only = payload['read_only'] == true
      true
    end

    # Route-only peek: is the bearer a JWT *claiming* to be a Cerberus assertion?
    # Reads `iss` WITHOUT verifying — you can't know which issuer/key applies
    # until you look, and the actual trust decision is made strictly in
    # {#resolve_cerberus_assertion}. A user-JWT (no `iss`) and a non-JWT bearer
    # both fall through to their own branches.
    def cerberus_assertion?
      payload, = JWT.decode(@token, nil, false)
      payload.is_a?(Hash) && payload['iss'] == CERBERUS_ISSUER
    rescue JWT::DecodeError
      false
    end

    # Strictly verify a Cerberus relay assertion and resolve its `sub` to a real
    # person (the operator). Reached only once the iss peek matched, so a failure
    # here is a hard reject (no fall-through): the caller declared itself a
    # Cerberus assertion. Identity is the signed `sub`; the `User:` header is not
    # consulted.
    #
    # Acting-as rides a SIGNED `obo` claim, never the On-Behalf-Of header on this
    # path. @on_behalf_of is set from the verified payload, OVERWRITING whatever
    # parse_headers read — so a header `On-Behalf-Of` can't be appended to a
    # stolen assertion to forge acting-as (absent an `obo` claim it resolves to
    # nil). The admin gate on the operator is applied in enforce_on_behalf_of_gate.
    def resolve_cerberus_assertion
      payload = verify_cerberus_assertion
      return render_error(:unauthorized, 'invalid cerberus assertion') if payload.nil?

      nuid = payload['sub']
      return render_error(:bad_request, 'cerberus assertion missing sub') if nuid.blank?

      # A NUID can hold several accounts (staff/student logins share it). An
      # optional signed `acct` (email) claim names which one is acting — its
      # stored group set drives authorization; absent, the person's preferred
      # account is used. `sub` stays the NUID (the grouping thread); the account
      # selector is additive. A named account that isn't one of this NUID's is a
      # 400, mirroring the unknown-principal case below.
      acct = payload['acct'].presence
      user = User.resolve_account(nuid: nuid, email: acct)
      if user.nil?
        return render_error(:bad_request,
                            acct ? "unknown account #{acct} for #{nuid}" : "unknown principal #{nuid}")
      end
      return render_error(:unauthorized, ':anonymous cannot authenticate') if user.anonymous?
      return render_error(:unauthorized, 'cerberus assertion must not name the :system fixture') if user.system?

      @auth_source  = :assertion
      @on_behalf_of = payload['obo'].presence
      @current_user = user
    end

    # Verify signature + claims of a Cerberus assertion. Pins `ES256` against the
    # public key named by the assertion's `kid` — never HS256 (which would open
    # the public-key-as-HMAC-secret algorithm-confusion attack) and never `none`.
    # `iss`/`aud`/`exp` are all enforced; a 30s leeway absorbs clock skew.
    # Returns the verified claims, or nil for any failure.
    def verify_cerberus_assertion
      keys = cerberus_signing_keys
      return nil if keys.empty?

      header = JWT.decode(@token, nil, false).last
      key = keys[header['kid']]
      return nil if key.nil?

      payload, = JWT.decode(@token, key, true,
                            algorithms:        ['ES256'],
                            verify_iss:        true, iss: CERBERUS_ISSUER,
                            verify_aud:        true, aud: CERBERUS_AUDIENCE,
                            verify_expiration: true, leeway: 30)
      payload
    rescue JWT::DecodeError, OpenSSL::PKey::PKeyError
      nil
    end

    # Cerberus's public signing keyset as { kid => OpenSSL::PKey }, parsed from
    # credentials.cerberus_signing_keys ({ kid => PEM }). Public keys only — safe
    # at rest, nothing to rotate-as-a-secret. Empty (the default until Cerberus
    # is provisioned) leaves the assertion path inert.
    def cerberus_signing_keys
      raw = Rails.application.credentials.cerberus_signing_keys
      return {} if raw.blank?

      raw.to_h.each_with_object({}) do |(kid, pem), acc|
        acc[kid.to_s] = OpenSSL::PKey.read(pem)
      end
    rescue OpenSSL::PKey::PKeyError
      {}
    end

    def valid_system_token?
      configured = Rails.application.credentials.system_token
      configured.present? && @token == configured
    end

    def guest_sign_in
      @current_user = User.find_by(role: :guest) # only one should exist
    end

    def render_error(status, message)
      render json: { error: message }, status: status
    end
end
