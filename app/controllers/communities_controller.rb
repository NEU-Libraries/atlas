# frozen_string_literal: true

# Communities
# rubocop:disable Metrics/ClassLength
class CommunitiesController < ApplicationController
  include LazyPagination
  include DelegateUris
  include StaleObjectRetry
  include Reparentable
  include Auditable
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

  def update
    @community = find_community(params[:id])
    authorize! :update, @community
    return head(:not_found) if @community.nil?

    if params[:binary].present?
      binary_update
    elsif params[:metadata].present?
      metadata_update
    end
  end

  def update_thumbnails
    with_stale_object_retry do
      @community = find_community(params[:id])
      authorize! :update_thumbnails, @community
      return head(:not_found) if @community.nil?

      apply_thumbnail_uris(resource_id: @community.id)
    end

    @community = Community.find(@community.id).decorate
    render :show
  end

  # Irreversible, and unlike tombstone it also refuses a member that is merely
  # tombstoned: a purge cannot be undone, so a member left behind here is
  # orphaned for good. An operator empties the tree leaf-first instead.
  def destroy
    @community = find_community(params[:id])
    authorize! :destroy, @community
    return head(:not_found) if @community.nil?

    if @community.filtered_children.any?
      render json:   { error: 'cannot destroy a community that still has members',
                       code:  'has_children' },
             status: :unprocessable_entity and return
    end

    ResourcePurger.call(resource: @community, actor_nuid: @current_user&.nuid,
                        on_behalf_of_nuid: @on_behalf_of)
  end

  def tombstone
    @community = find_community(params[:id])
    authorize! :tombstone, @community
    return head(:not_found) if @community.nil?

    if @community.live_children?
      render json:   { error: 'cannot tombstone a non-empty community',
                       code:  'has_live_children' },
             status: :unprocessable_entity and return
    end

    @community.tombstone(by: @current_user&.nuid)
    @community = Atlas.persister.save(resource: @community).decorate
    audit!(resource: @community, action: 'tombstone', change_type: 'lifecycle')
  end

  def restore
    @community = find_community(params[:id])
    authorize! :restore, @community
    return head(:not_found) if @community.nil?

    @community.restore
    @community = Atlas.persister.save(resource: @community).decorate
    audit!(resource: @community, action: 'restore', change_type: 'lifecycle')
  end

  # Move a Community under a different Community, or to the top of the tree
  # (omit parent_id / pass null). Re-projects the moved subtree's descendant
  # collections + sub-communities (Reparentable).
  def update_parent
    reparent(Community)
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

    def binary_update
      file = params[:binary]
      path = file.tempfile.path.presence || file.path
      @community.mods_xml = File.read(path)
      @community = Atlas.persister.save(resource: @community)
      audit!(resource: @community, action: 'update', change_type: 'metadata', payload: { source: 'mods' })
    end

    def metadata_update
      @community = audited_metadata_update(@community)
    end
end
# rubocop:enable Metrics/ClassLength
