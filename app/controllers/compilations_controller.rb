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

  # Grant-scoped listing modes. Default (no `?scope=`) is owner-scoped and
  # backward compatible.
  GRANT_SCOPES = %w[editable shared].freeze

  # GET /compilations — newest-first listing. Three modes:
  #   - default (no `?scope=`): the caller's own Sets. `?owner=<nuid>` lists
  #     another user's (admin-only); there is no public browse endpoint.
  #   - `?scope=editable`: Sets the caller may edit but does not own
  #     (edit_users / edit_groups grants).
  #   - `?scope=shared`: Sets shared with the caller but not owned (read_groups
  #     grants, plus the edit grants that imply read).
  # `?q=<term>` narrows by case-insensitive title substring in every mode,
  # applied before pagination so the pagination block describes the filtered
  # result.
  def index
    authorize! :read, Compilation
    if params[:scope].present? && GRANT_SCOPES.exclude?(params[:scope])
      return render_error(:bad_request, "unknown scope #{params[:scope]} (expected: #{GRANT_SCOPES.join(', ')})")
    end

    pagy, @compilations = pagy(filtered_scope)
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

  # GET /compilations/:id/contents — resolve the recipe into Work digests
  # (the CERES-facing read). Solr-side pagination; visibility is gated per
  # caller inside the query (Cerberus gated-discovery parity).
  def contents
    @compilation = find_compilation
    authorize! :read, @compilation

    result = CompilationContentsQuery.call(
      compilation: @compilation, user: @current_user,
      page: params[:page], per_page: params[:per_page]
    )
    @contents   = result.digests
    @pagination = result.pagination
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

    # Grant-scoped listing keyed on the acting principal (never a `?owner=`);
    # `?scope=editable` excludes read-only grants, `?scope=shared` includes
    # them. Group membership is resolved server-side from @current_user.
    def grant_scope(include_read:)
      Compilation.granted_to(nuid:         @current_user&.nuid,
                             groups:       @current_user&.groups,
                             include_read: include_read)
    end

    def base_scope
      case params[:scope]
      when 'editable' then grant_scope(include_read: false)
      when 'shared'   then grant_scope(include_read: true)
      else owner_scope
      end
    end

    def filtered_scope
      scope = base_scope
      return scope if params[:q].blank?

      scope.where('title ILIKE ?', "%#{Compilation.sanitize_sql_like(params[:q])}%")
    end
end
