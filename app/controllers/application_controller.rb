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
    end

    # Resolve @current_user from the (Bearer token, User: NUID) pair.
    #
    #   token == cerberus_token + User present + known        → that user
    #   token == cerberus_token + User present + :anonymous   → 401 (Q2 hard guard)
    #   token == cerberus_token + User present + unknown NUID → 400
    #   token == cerberus_token + User missing                → 400
    #   token blank                                           → guest (read-only)
    #   token present but mismatched                          → 401
    #
    # The pre-piece-2 behavior was looser in two places: a missing User
    # header implicitly resolved to :system, and a mismatched token fell
    # through to guest instead of 401-ing. Both were silent
    # privilege-elevation footguns and are now hard rejections.
    def require_auth
      parse_headers
      return guest_sign_in if @token.blank?
      return render_error(:unauthorized, 'invalid bearer token') unless valid_cerberus_token?
      return render_error(:bad_request, 'User: NUID header required') if @nuid.blank?

      user = User.find_by(nuid: @nuid)
      return render_error(:bad_request, "unknown principal #{@nuid}") if user.nil?
      return render_error(:unauthorized, ':anonymous cannot authenticate') if user.anonymous?

      @current_user = user
    end

    def valid_cerberus_token?
      @token == Rails.application.credentials.cerberus_token
    end

    def guest_sign_in
      @current_user = User.find_by(role: :guest) # only one should exist
    end

    def render_error(status, message)
      render json: { error: message }, status: status
    end
end
