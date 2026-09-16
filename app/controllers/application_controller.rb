# frozen_string_literal: true

# The single auth gate every request passes through. See
# docs/authentication.md for the credential paths, the resolution matrix and
# the acting-as rules, and docs/error-contract.md for the failure shapes the
# rescue_from handlers below render.
class ApplicationController < ActionController::API
  include ActionController::MimeResponds
  include CanCan::ControllerAdditions

  respond_to :json

  # `iss`/`aud` bind a Cerberus assertion to this exchange; both are verified.
  CERBERUS_ISSUER   = 'cerberus'
  CERBERUS_AUDIENCE = 'atlas'

  # The only actions a read-only credential may reach, shared by the per-token
  # and repository-wide floors in #authorize! below. An allowlist on purpose: a
  # write-shaped action added later is refused without being enumerated here.
  READ_ONLY_TOKEN_ACTIONS = %i[read read_directory read_versions index_all preview].freeze

  before_action :require_auth

  # Raises CanCan::AuthorizationNotPerformed when an action forgets to call
  # authorize!, so a new endpoint without a gate fails its first test.
  check_authorization unless: :public_endpoint?

  # Carries the ability metadata so callers can branch on which verb was
  # refused rather than parsing the message.
  rescue_from CanCan::AccessDenied do |exception|
    render json: {
      error:   exception.message,
      action:  exception.action,
      subject: exception.subject.is_a?(Class) ? exception.subject.name : exception.subject.class.name
    }, status: :forbidden
  end

  # A bare 404 below, matching the head(:not_found) the Valkyrie controllers
  # render for an unknown noid, so both tiers answer a miss identically.
  rescue_from ActiveRecord::RecordInvalid do |exception|
    render json: {
      error:   'invalid_record',
      message: exception.message
    }, status: :unprocessable_content
  end

  rescue_from ActiveRecord::RecordNotFound do
    head :not_found
  end

  # `stale_resource` is an exact-match wire contract: atlas_rb keys on it to
  # raise AtlasRb::StaleResourceError. Do not change it without a contract bump.
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

  # `error` carries the exception's machine-readable code so atlas_rb can raise
  # a typed error; `message` is the human-readable detail. Same contract on the
  # five handlers below.
  rescue_from Exceptions::ReparentError do |exception|
    render json: {
      error:       exception.code,
      resource_id: params[:id],
      message:     exception.message
    }, status: :unprocessable_content
  end

  rescue_from Exceptions::LinkedMemberError do |exception|
    render json: {
      error:       exception.code,
      resource_id: params[:id],
      message:     exception.message
    }, status: :unprocessable_content
  end

  rescue_from Exceptions::WorkAssociationError do |exception|
    render json: {
      error:       exception.code,
      resource_id: params[:id],
      message:     exception.message
    }, status: :unprocessable_content
  end

  rescue_from Exceptions::FixityMismatch do |exception|
    render json: {
      error:       exception.code,
      resource_id: params[:id],
      message:     exception.message
    }, status: :unprocessable_content
  end

  rescue_from Exceptions::DerivativePermissionsError do |exception|
    render json: {
      error:       exception.code,
      resource_id: params[:id],
      message:     exception.message
    }, status: :unprocessable_content
  end

  rescue_from Exceptions::PermissionsError do |exception|
    render json: {
      error:       exception.code,
      resource_id: params[:id],
      message:     exception.message
    }, status: :unprocessable_content
  end

  # A 503 and not a 403: during a window the caller's rights are fine and the
  # repository is closed. `read_only_mode` is an exact-match wire contract --
  # atlas_rb raises AtlasRb::ReadOnlyModeError on it.
  rescue_from Exceptions::ReadOnlyMode do |exception|
    response.headers['Retry-After'] = MaintenanceMode.retry_after.to_s
    render json: {
      error:   Exceptions::ReadOnlyMode::CODE,
      message: exception.message
    }, status: :service_unavailable
  end

  private

    # CanCan looks up `current_user`; Atlas's shape sets @current_user in
    # require_auth, so the helper sources from it.
    def current_ability
      @current_ability ||= Ability.new(@current_user, on_behalf_of: @on_behalf_of)
    end

    # Any endpoint returning a LIST must apply the read gate per row, or it
    # hands back exactly what the gate on the single-resource route refuses.
    def readable(resources)
      Array(resources).select { |resource| can?(:read, resource) }
    end

    # Both floors sit in front of the real check rather than inside Ability, so
    # no grant -- present or future -- can bypass them. Raising the same
    # CanCan::AccessDenied a normal denial would means no separate rescue path.
    def authorize!(action, subject, *args)
      raise Exceptions::ReadOnlyMode if repository_read_only?(action)

      if @token_read_only && READ_ONLY_TOKEN_ACTIONS.exclude?(action)
        raise CanCan::AccessDenied.new('read-only token cannot perform this action', action, subject)
      end

      super
    end

    # Nothing is exempted, GET /reset included -- its RESETTABLE_ENVS guard is
    # a separate concern.
    def repository_read_only?(action)
      return false if read_only_exempt?
      return false if READ_ONLY_TOKEN_ACTIONS.include?(action)

      MaintenanceMode.read_only?
    end

    # Overridden only by PUT /maintenance, which is what keeps the window
    # closable. Everything else is refused: the floor is fail-closed.
    def read_only_exempt?
      false
    end

    # None today. DocsController inherits ActionController::Base and is exempt
    # by class; this stays as the escape hatch for a future health check.
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

      # Parsed only so enforce_on_behalf_of_gate can reject it: acting-as is
      # NOT header-driven. The assertion path overwrites this from the signed
      # `obo` claim; every other path 403s on a present header.
      obo_header = request.headers['On-Behalf-Of']
      @on_behalf_of = obo_header.gsub(nuid_pattern, '') if obo_header&.match(nuid_pattern)
    end

    # Dispatch order is fixed: blank, system token, Cerberus assertion,
    # devise-jwt. docs/authentication.md carries the full resolution matrix.
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

      # `performed?` guards against a double render: the branches above bail
      # with a rendered error.
      enforce_on_behalf_of_gate unless performed?
    end

    # Two cases pass: an admin on the assertion path, and :system. The
    # @auth_source check is load-bearing -- it is :assertion only for the
    # signed-claim path, so a stray header on the JWT-direct or guest path
    # 403s even for an admin.
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

    # Routed through warden rather than hand-decoded, because the strategy runs
    # TokenDecoder AND the JTIMatcher revocation check and converts every
    # failure to a clean `fail!` -- so this returns nil, never an exception.
    #
    # The :system/:anonymous rejection is the wire backstop: minting is already
    # gated to real persons, but a personal token must never reach a bookend.
    #
    # Re-decoding for the read_only claim is safe -- the warden call above
    # already verified signature, revocation and expiry via this same decoder.
    def resolve_jwt_user
      user = request.env['warden']&.authenticate(:jwt, scope: :user)
      return if user.nil? || user.system? || user.anonymous?

      @current_user = user
      payload = Warden::JWTAuth::TokenDecoder.new.call(@token)
      @token_read_only = payload['read_only'] == true
      true
    end

    # Route-only peek. Reads `iss` WITHOUT verifying, because you cannot know
    # which key applies until you look; the trust decision is made strictly in
    # resolve_cerberus_assertion.
    def cerberus_assertion?
      payload, = JWT.decode(@token, nil, false)
      payload.is_a?(Hash) && payload['iss'] == CERBERUS_ISSUER
    rescue JWT::DecodeError
      false
    end

    # A failure here is a hard reject with no fall-through: the caller declared
    # itself a Cerberus assertion. Identity is the signed `sub`.
    #
    # @on_behalf_of is set from the verified payload, OVERWRITING whatever
    # parse_headers read, so a header cannot be appended to a stolen assertion
    # to forge acting-as.
    def resolve_cerberus_assertion
      payload = verify_cerberus_assertion
      return render_error(:unauthorized, 'invalid cerberus assertion') if payload.nil?

      nuid = payload['sub']
      return render_error(:bad_request, 'cerberus assertion missing sub') if nuid.blank?

      # One NUID can hold several accounts (staff and student logins share it).
      # The optional signed `acct` claim names which one is acting, and its
      # group set drives authorization; `sub` stays the NUID.
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

    # ES256 is PINNED. Never HS256 -- that opens the public-key-as-HMAC-secret
    # algorithm-confusion attack -- and never `none`. iss/aud/exp are all
    # enforced; the 30s leeway absorbs clock skew.
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

    # Public keys only, so nothing here is a secret to rotate. An empty keyset
    # -- the default until Cerberus is provisioned -- leaves the assertion path
    # inert.
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
