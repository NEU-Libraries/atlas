# frozen_string_literal: true

class ApplicationController < ActionController::API
  include ActionController::MimeResponds
  respond_to :json

  before_action :require_auth

  private

    def parse_headers
      token_pattern = /^Bearer /
      token_header  = request.headers['Authorization']
      @token = token_header.gsub(token_pattern, '') if token_header && token_header.match(token_pattern)

      nuid_pattern = /^NUID /
      nuid_header  = request.headers['User']
      @nuid = nuid_header.gsub(nuid_pattern, '') if nuid_header && nuid_header.match(nuid_pattern)
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

      user = User.find_by_nuid(@nuid)
      return render_error(:bad_request, "unknown principal #{@nuid}") if user.nil?
      return render_error(:unauthorized, ':anonymous cannot authenticate') if user.anonymous?

      @current_user = user
    end

    def valid_cerberus_token?
      @token == Rails.application.credentials.cerberus_token
    end

    def guest_sign_in
      @current_user = User.find_by_role(:guest) # only one should exist
    end

    # Per-endpoint allowlist guard. The :system principal exists for
    # service-to-service operations (currently just SSO user provisioning);
    # it must not be able to author repository resources. Mount this as a
    # before_action with `only:` on each write action that should reject
    # system callers. Per Q7 (settled lean), container creates
    # (Communities/Collections #create) currently still accept the system
    # principal so the seed task can run — the rest of the write surface
    # rejects it.
    def reject_system_principal
      return unless @current_user&.system?

      render_error(:forbidden, 'system principal cannot author resources')
    end

    def render_error(status, message)
      render json: { error: message }, status: status
    end
end
