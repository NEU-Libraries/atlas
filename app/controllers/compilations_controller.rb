# frozen_string_literal: true

# Compilations (DRS "Sets") — personal, recipe-based groupings of Works and
# Collections. Pure AR controller (like UsersController): no Valkyrie
# persister, no preservation envelope — Sets are ephemeral curation, not
# repository content. Lookups are by noid (find_by!; unknown → 404 via the
# RecordNotFound rescue); the pk never reaches the wire.
class CompilationsController < ApplicationController
  include Pagy::Backend
  include Auditable
  include CompilationMemberships

  # GET /compilations — owner-scoped listing, newest first. `?owner=<nuid>`
  # (cross-owner listing) is admin-only; there is no public browse endpoint
  # in the first pass.
  def index
    authorize! :read, Compilation
    pagy, @compilations = pagy(owner_scope)
    @pagination = pagy_metadata(pagy)
  end

  def show
    @compilation = find_compilation
    authorize! :read, @compilation
  end

  def create
    authorize! :create, Compilation
    @compilation = Compilation.create!(
      title:       params[:title],
      description: params[:description],
      depositor:   @current_user&.nuid
    )
    render :show, status: :created
  end

  # PATCH /compilations/:id — title/description plus an optional
  # `permissions` ACL hash. ACL writes capture audited_acl before/after and
  # emit a `permissions` audit row, suppressing no-ops — same convention as
  # the resource metadata PATCH (Auditable#audit_metadata_update!). Recipe
  # churn (the membership routes) deliberately emits nothing.
  def update
    @compilation = find_compilation
    authorize! :update, @compilation

    @compilation.title       = params[:title] if params[:title].present?
    @compilation.description = params[:description] if params.key?(:description)
    before_acl = apply_permissions_params
    @compilation.save!
    audit_metadata_update!(resource: @compilation, before_acl: before_acl)
    render :show
  end

  def destroy
    @compilation = find_compilation
    authorize! :destroy, @compilation
    @compilation.destroy!
    head :no_content
  end

  private

    def find_compilation
      Compilation.find_by!(noid: params[:id])
    end

    # Returns the pre-edit audited ACL when the request carried a
    # permissions key (captured BEFORE reassignment, mirroring
    # Auditable#apply_metadata_params), otherwise nil.
    def apply_permissions_params
      return nil if params[:permissions].blank?

      before_acl = @compilation.audited_acl
      @compilation.permissions =
        params.require(:permissions).permit(read: [], edit: [], edit_users: [])
      before_acl
    end

    def owner_scope
      owner = params[:owner].presence || @current_user&.nuid
      if owner != @current_user&.nuid && !@current_user&.admin?
        raise CanCan::AccessDenied.new('cross-owner listing is admin-only', :read, Compilation)
      end

      Compilation.where(depositor: owner).order(created_at: :desc)
    end
end
