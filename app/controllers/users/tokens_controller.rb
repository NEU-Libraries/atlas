# frozen_string_literal: true

module Users
  class TokensController < ApplicationController
    # GET /user — the acting account's details (flat AR fields; atlas_rb reads
    # `groups`/`id`/`name` off the top level). `?email=` reads a *specific* one
    # of the caller's other accounts under the same NUID (the switch flow reads
    # a chosen account before adopting it) — allowed only for the caller's own
    # accounts, an admin, or the system principal; a foreign account is 403.
    def show
      authorize! :read, User

      user = selected_account
      return if performed?

      render json: user.to_json
    end

    # Mint a personal-access JWT for a real person. System-gated (mint_token →
    # :system only) because minting for an arbitrary NUID is "become anyone" —
    # Cerberus calls this post-SSO and hands the token back to the librarian.
    #
    # An optional `read_only` flag rides into the token as a custom claim
    # (see ApplicationController#resolve_jwt_user / #authorize!) — this is
    # the shape handed to non-human callers (e.g. an MCP client) that should
    # never be able to mutate the repository, independent of what the
    # underlying person could otherwise do. Warden::JWTAuth::UserEncoder has
    # no per-call custom-claims hook (its third positional arg is `aud`), so
    # the payload is built by hand from the same PayloadUserHelper/TokenEncoder
    # UserEncoder uses internally, with `read_only` merged in only for this
    # one mint — unlike overriding User#jwt_payload, this can't leak onto a
    # different token minted for the same user without the flag.
    def nuid
      authorize! :mint_token, User

      user = User.resolve_account(nuid: params[:nuid], email: params[:email])
      return head(:not_found) if user.blank?

      read_only = params[:read_only] == true
      payload = Warden::JWTAuth::PayloadUserHelper.payload_for_user(user, :user).merge('aud' => nil)
      payload['read_only'] = true if read_only
      token = Warden::JWTAuth::TokenEncoder.new.call(payload)
      audit_token_event('mint_token', user, read_only: read_only)
      render json: { token: token }.to_json
    end

    # Revoke every outstanding token for a user by rotating its jti (single-jti
    # model → all-or-nothing). System-gated like minting. "Regenerate token" on
    # the Cerberus side is revoke followed by a fresh mint.
    def revoke
      authorize! :mint_token, User

      user = User.resolve_account(nuid: params[:nuid], email: params[:email])
      return head(:not_found) if user.blank?

      User.revoke_jwt(nil, user) # JTIMatcher: user.update_column(:jti, new uuid)
      audit_token_event('revoke_token', user)
      head :no_content
    end

    private

      # The account whose details GET /user should return: the acting user by
      # default, or the `?email=` one when it belongs to the caller's NUID (or
      # the caller is admin/system). Renders 403/404 and returns nil otherwise.
      def selected_account
        return @current_user if params[:email].blank?

        account = User.find_by(email: params[:email])
        if account.nil?
          head(:not_found)
          return nil
        end
        unless account.nuid == @current_user.nuid || @current_user.admin? || @current_user.system?
          head(:forbidden)
          return nil
        end
        account
      end

      # Token lifecycle is a credential grant/revoke on a user — the same shape
      # `permissions` already serves for role/grant mutations (target NUID in
      # payload, no repository resource). Actor is the :system operator.
      def audit_token_event(action, user, **extra_payload)
        AuditEventWriter.record(
          actor_nuid:   @current_user.nuid,
          action:       action,
          change_type:  'permissions',
          event_source: 'controller',
          payload:      { target_nuid: user.nuid }.merge(extra_payload)
        )
      end
  end
end
