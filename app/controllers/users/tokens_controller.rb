# frozen_string_literal: true

module Users
  class TokensController < ApplicationController
    def show
      authorize! :read, User
      render json: @current_user.to_json
    end

    # Mint a personal-access JWT for a real person. System-gated (mint_token →
    # :system only) because minting for an arbitrary NUID is "become anyone" —
    # Cerberus calls this post-SSO and hands the token back to the librarian.
    def nuid
      authorize! :mint_token, User

      user = User.find_by(nuid: params[:nuid])
      return head(:not_found) if user.blank?

      token = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)[0]
      audit_token_event('mint_token', user)
      render json: { token: token }.to_json
    end

    # Revoke every outstanding token for a user by rotating its jti (single-jti
    # model → all-or-nothing). System-gated like minting. "Regenerate token" on
    # the Cerberus side is revoke followed by a fresh mint.
    def revoke
      authorize! :mint_token, User

      user = User.find_by(nuid: params[:nuid])
      return head(:not_found) if user.blank?

      User.revoke_jwt(nil, user) # JTIMatcher: user.update_column(:jti, new uuid)
      audit_token_event('revoke_token', user)
      head :no_content
    end

    private

      # Token lifecycle is a credential grant/revoke on a user — the same shape
      # `permissions` already serves for role/grant mutations (target NUID in
      # payload, no repository resource). Actor is the :system operator.
      def audit_token_event(action, user)
        AuditEventWriter.record(
          actor_nuid:   @current_user.nuid,
          action:       action,
          change_type:  'permissions',
          event_source: 'controller',
          payload:      { target_nuid: user.nuid }
        )
      end
  end
end
