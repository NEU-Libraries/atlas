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

  def update
    authorize! :provision, User

    @user = UserProvisioner.call(
      nuid:   params[:nuid],
      groups: Array(params[:groups]),
      email:  params[:email],
      name:   params[:name]
    )
    render :update
  end

  private

    def batch_nuids
      params[:nuids].to_s.split(',').map(&:strip).compact_blank.first(BATCH_LIMIT)
    end
end
