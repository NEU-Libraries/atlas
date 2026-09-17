# frozen_string_literal: true

# Communities
class CommunitiesController < ApplicationController
  include LazyPagination
  include CachedResponses
  include ParentScopedCreate

  # Container creation is intentionally left open to :system so the seed task
  # can bootstrap Communities + Collections. The :system carve-out for :create
  # lives in Ability#apply_role_abilities; it can be retired once a dedicated
  # container-creation role exists.

  # The unfiltered roll of every Community. :index_all is admin-only (via the
  # manage :all wildcard) for the same reason as WorksController#index — a
  # paginated list cannot honour the per-resource read gate row by row.
  def index
    authorize! :index_all, Community
    @pagination, @communities = paginate_model(Community)
    MODSPreloader.call(resources: @communities)
  end

  def show
    resource = find_community(params[:id])
    authorize! :read, resource || Community
    return head(:not_found) if resource.nil?

    cached_render('communities.show', resource) do
      @community = resource.decorate

      render :show, status: (@community.tombstoned ? :gone : :ok)
    end
  end

  # A Community may legitimately be parentless (top of tree), so a blank
  # parent_id creates a root; a given-but-unresolvable one is still a 404.
  def create
    authorize! :create, Community
    parent = authorized_create_parent(params[:parent_id])
    return head(:not_found) if parent.nil? && params[:parent_id].present?

    # TODO: XML
    @community = CommunityCreator.call(
      parent_id:         parent&.noid,
      proxy_uploader:    proxy_uploader_nuid,
      depositor:         depositor_nuid,
      actor_nuid:        @current_user&.nuid,
      on_behalf_of_nuid: @on_behalf_of
    )
  end

  def mods
    # TODO: support raw XML, in addition to JSON and HTML
    community = find_community(params[:id])
    authorize! :read, community || Community
    return head(:not_found) if community.nil? || community.mods.nil?

    cached_render(format_scope('communities.mods'), community) do
      @community = community.decorate
      render :mods
    end
  end

  # Child NOIDs, filtered to the ones this caller may read. A public container
  # can hold a restricted child, and listing that child's NOID here would hand
  # back the id the gated single-resource route refuses to serve.
  def children
    resource = find_community(params[:id])
    authorize! :read, resource || Community
    return head(:not_found) if resource.nil?

    @community = resource.decorate
    return render(:show, status: :gone) if @community.tombstoned

    @children = readable(@community.filtered_child_resources).map { |child| child.noid.to_s }
  end

  private

    # Resolve :id to a Community, or nil if the id is absent OR names a
    # resource of another type. Valkyrie's `Community.find` is not
    # type-scoped, so a hand-edited /communities/<work-id> would otherwise feed
    # a non-Community into the Community serializer and 500. Collapsing a
    # wrong-type id to nil keeps the endpoint's type contract: it 404s exactly
    # like an unknown id. (Mirrors WorksController#find_work.)
    def find_community(id)
      community = Community.find(id)
      community if community.is_a?(Community)
    end

    # Mirror of WorksController's provenance helpers — see that file for
    # the full rationale. Communities are roots, so there's no parent
    # depositor to inherit; depositor falls back directly to the
    # proxy_uploader.
    def proxy_uploader_nuid
      return nil if @on_behalf_of.present?

      @current_user&.nuid
    end

    def depositor_nuid
      return params[:depositor] if params[:depositor].present?
      return @on_behalf_of      if @on_behalf_of.present?

      proxy_uploader_nuid
    end
end
