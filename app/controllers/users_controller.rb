# frozen_string_literal: true

class UsersController < ApplicationController
  # Read-only directory caps: typeahead lists stay small; batch resolve
  # covers an inbox page of senders in one call without becoming a dump.
  SEARCH_LIMIT = 10
  BATCH_LIMIT  = 100

  # GET /users?q=<fragment> — typeahead search (capped, name-ordered).
  # GET /users?nuids=a,b,c — batch NUID resolve, same response shape.
  # Minimal disclosure: entries carry nuid + name only.
  def index
    authorize! :read, User

    @users = if params[:nuids].present?
               User.directory.where(nuid: batch_nuids).order(:name)
             elsif params[:q].present?
               User.directory_search(params[:q]).order(:name).limit(SEARCH_LIMIT)
             else
               User.none
             end
  end

  # GET /users/by_nuid/:nuid — single resolve. Excluded roles read as
  # absent (404), same as an unknown NUID.
  def show
    authorize! :read, User

    @user = User.directory.find_by(nuid: params[:nuid])
    head(:not_found) if @user.nil?
  end

  # PUT /users/by_email/:email — the canonical SSO provisioning endpoint.
  # Email is the account key, so a person's staff and student logins provision
  # as distinct accounts sharing one NUID instead of collapsing. System-only.
  def update_by_email
    authorize! :provision, User

    @user = UserProvisioner.call(
      email:       params[:email],
      nuid:        params[:nuid],
      groups:      Array(params[:groups]),
      name:        params[:name],
      affiliation: params[:affiliation]
    )
    render :update
  end

  # PUT /users/by_nuid/:nuid — kept for backward compatibility. When the body
  # carries an email (Cerberus already sends it), delegates to the email-keyed
  # provisioner so live SSO stops collapsing accounts on NUID; with no email it
  # falls back to the legacy behavior — replace the groups on the NUID's single
  # existing account (email is required to create, so a missing account is 404).
  def update
    authorize! :provision, User

    @user =
      if params[:email].present?
        UserProvisioner.call(email: params[:email], nuid: params[:nuid],
                             groups: Array(params[:groups]), name: params[:name],
                             affiliation: params[:affiliation])
      else
        legacy_update_by_nuid
      end
    return if performed?

    render :update
  end

  # GET /users/by_nuid/:nuid/accounts — every account sharing this NUID (a
  # person's logins), each with email/affiliation/role/groups and the preferred
  # flag. Powers login-time "you have more than one account" detection and the
  # My DRS accounts panel. Discloses group sets + emails, so it is limited to
  # the person themselves, an admin, or the system principal.
  def accounts
    authorize! :read, User
    return head(:forbidden) unless account_scope_authorized?(params[:nuid])

    @nuid     = params[:nuid]
    @accounts = User.accounts_for(@nuid)
  end

  # PUT /users/by_nuid/:nuid/preferred_account  body: { email: }
  # Set the person's default account (drives the login choice when no account
  # is named). Same self/admin/system scope as #accounts. Unknown email for
  # this NUID → 404.
  def preferred_account
    authorize! :read, User
    return head(:forbidden) unless account_scope_authorized?(params[:nuid])

    @user = User.find_by(nuid: params[:nuid], email: params[:email])
    return head(:not_found) if @user.nil?

    @user.make_preferred!
    render :update
  end

  private

    def batch_nuids
      params[:nuids].to_s.split(',').map(&:strip).compact_blank.first(BATCH_LIMIT)
    end

    # Legacy no-email by_nuid path: group-replace on the NUID's single existing
    # account. Renders 404 when the NUID has no account (can't create without an
    # email); the caller checks `performed?` before rendering the success view.
    def legacy_update_by_nuid
      user = User.accounts_for(params[:nuid]).first
      return head(:not_found) if user.nil?

      user.update!(groups: Array(params[:groups]).map(&:to_s).uniq)
      user
    end

    # Account enumeration/preference exposes a person's group sets, so it is not
    # open directory data: only the person themselves (matching NUID), an admin,
    # or the system principal may reach it.
    def account_scope_authorized?(nuid)
      @current_user.nuid == nuid || @current_user.admin? || @current_user.system?
    end
end
