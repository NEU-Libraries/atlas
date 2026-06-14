# frozen_string_literal: true

class ApplicationController < ActionController::API
  include ActionController::MimeResponds
  include CanCan::ControllerAdditions
  respond_to :json

  before_action :require_auth

  # Strict mode: any controller action that forgets to call `authorize!`
  # raises CanCan::AuthorizationNotPerformed. The piece-2 footgun ("add
  # reject_system_principal to every new write action") becomes
  # structurally impossible — adding a new endpoint without authorize!
  # fails its first test.
  check_authorization unless: :public_endpoint?

  # Structured 403 for ability denials. The piece-2 shape was
  # `{ error: "system principal cannot author resources" }` (specific
  # to one rule); the new shape carries the ability metadata so
  # callers can branch on action/subject if needed.
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

  private

    # CanCan looks up `current_user` to construct the Ability. Atlas's
    # auth shape is Bearer + NUID header (require_auth above) which sets
    # @current_user; override the CanCan helper to source from it.
    def current_ability
      @current_ability ||= Ability.new(@current_user)
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

      # Acting-as (piece 5): the operator authorizes with the `User` header;
      # `On-Behalf-Of` carries the attribution target, same `NUID <nuid>`
      # shape. Admin-gated below — see enforce_on_behalf_of_gate.
      obo_header = request.headers['On-Behalf-Of']
      @on_behalf_of = obo_header.gsub(nuid_pattern, '') if obo_header&.match(nuid_pattern)
    end

    # Resolve @current_user from the bearer token (+ User: NUID pair for the
    # shared-secret credentials).
    #
    # Three bearer credentials are recognized:
    #
    #   cerberus_token  — Cerberus's user-facing wire token. Pairs with the
    #                     `User: NUID` header for any real-person principal
    #                     (NOT :system). Identity comes from the header.
    #   system_token    — atlas_rb's System namespace token. Pairs only
    #                     with the :system fixture.
    #   devise-jwt      — a JWT minted for a real person by POST /nuid (the
    #                     Cerberus-delegated, standalone-API path). Identity
    #                     comes from the TOKEN, not the header; the JTIMatcher
    #                     revocation + expiry checks run inside the warden
    #                     :jwt strategy. Never resolves :system/:anonymous.
    #
    # Matrix:
    #
    #   blank token                          → guest (read-only)
    #   cerberus_token + User missing        → 400
    #   cerberus_token + unknown NUID        → 400
    #   cerberus_token + :anonymous          → 401 (Q2 hard guard)
    #   cerberus_token + :system NUID        → 401 (pairing rule)
    #   cerberus_token + real-person NUID    → that user
    #   system_token + User missing          → 400
    #   system_token + unknown NUID          → 400
    #   system_token + non-:system NUID      → 401 (pairing rule)
    #   system_token + :system NUID          → :system
    #   valid JWT (real person)              → that user (header ignored)
    #   JWT for :system / :anonymous         → 401 (bookend guard)
    #   expired / revoked / malformed JWT    → 401
    #   any other token                      → 401
    #
    # Pre-piece-6 had a single token. The pairing split closes the
    # leaked-token-cross-pairing footgun: a stolen user token can't
    # impersonate :system, and a stolen system token can't impersonate
    # any real person. The JWT path was added after (standalone-API access);
    # it is gated to real persons and carries no acting-as authority.
    def require_auth
      parse_headers

      if @token.blank?
        guest_sign_in
      elsif valid_cerberus_token?
        resolve_cerberus_user
      elsif valid_system_token?
        resolve_system_user
      elsif resolve_jwt_user
        # @current_user is set inside resolve_jwt_user — identity is in the token
      else
        return render_error(:unauthorized, 'invalid bearer token')
      end

      # Runs only if a principal was resolved (the branches above bail with a
      # rendered error otherwise; `performed?` guards against a double render).
      enforce_on_behalf_of_gate unless performed?
    end

    # Acting-as authorization (piece 5 / Q16): the operator authorizes the
    # request, the target is only an attribution stamp and needs no rights —
    # so `On-Behalf-Of` is restricted to admin operators. A non-admin (incl.
    # guest and the :system principal) presenting it is rejected. This is the
    # wire boundary; the proxy_uploader-null-under-impersonation rule and the
    # two-principal AuditEvent both hang off @on_behalf_of downstream.
    #
    # Acting-as is a Cerberus-RELAY concept: it only makes sense when an
    # operator authorizes with the cerberus_token and names a separate
    # attribution target. A JWT-direct principal IS the actor (the token carries
    # the identity) and has no operator/target split, so On-Behalf-Of is
    # rejected on the JWT path even for an admin — likewise on the system and
    # guest paths. Only cerberus_token + admin may act-as, so the gate
    # re-derives the path from the token rather than tracking auth state.
    def enforce_on_behalf_of_gate
      return if @on_behalf_of.blank?
      return if valid_cerberus_token? && @current_user&.admin?

      render_error(:forbidden, 'On-Behalf-Of requires an admin operator')
    end

    def resolve_cerberus_user
      return render_error(:bad_request, 'User: NUID header required') if @nuid.blank?

      user = User.find_by(nuid: @nuid)
      return render_error(:bad_request, "unknown principal #{@nuid}") if user.nil?
      return render_error(:unauthorized, ':anonymous cannot authenticate') if user.anonymous?
      return render_error(:unauthorized, 'user token must not be paired with the :system fixture') if user.system?

      @current_user = user
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
    def resolve_jwt_user
      user = request.env['warden']&.authenticate(:jwt, scope: :user)
      return if user.nil? || user.system? || user.anonymous?

      @current_user = user
    end

    def valid_cerberus_token?
      configured = Rails.application.credentials.cerberus_token
      configured.present? && @token == configured
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
