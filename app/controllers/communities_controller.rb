# frozen_string_literal: true

# Communities
class CommunitiesController < ApplicationController
  include LazyPagination
  include DelegateUris
  include StaleObjectRetry

  # Container creation is intentionally left open to :system (Q7 lean) so the
  # seed task can bootstrap Communities + Collections. The :system carve-out
  # for :create lives in Ability#apply_role_abilities; once a dedicated
  # container-creation role exists, that carve-out goes away.

  def index
    authorize! :read, Community
    @pagination, @communities = paginate_model(Community)
  end

  def show
    authorize! :read, Community
    @community = Community.find(params[:id])&.decorate
    return head(:not_found) if @community.nil?

    render :show, status: (@community.tombstoned ? :gone : :ok)
  end

  def create
    authorize! :create, Community
    # TODO: XML
    @community = CommunityCreator.call(
      parent_id:         params[:parent_id],
      proxy_uploader:    proxy_uploader_nuid,
      depositor:         depositor_nuid,
      actor_nuid:        @current_user&.nuid,
      on_behalf_of_nuid: @on_behalf_of
    )
  end

  def mods
    authorize! :read, Community
    # TODO: support raw XML, in addition to JSON and HTML
    community = Community.find(params[:id])
    return head(:not_found) if community.nil? || community.mods.nil?

    @community = community.decorate
  end

  def children
    authorize! :read, Community
    @community = Community.find(params[:id])&.decorate
    return head(:not_found) if @community.nil?
    return render(:show, status: :gone) if @community.tombstoned

    @children = @community.filtered_children
  end

  def ancestors
    authorize! :read, Community
    @community = Community.find(params[:id])&.decorate
    return head(:not_found) if @community.nil?
    return render(:show, status: :gone) if @community.tombstoned

    @ancestors = @community.ancestors
  end

  def update
    @community = Community.find(params[:id])
    authorize! :update, @community

    if params[:binary].present?
      binary_update
    elsif params[:metadata].present?
      metadata_update
    end
  end

  def update_thumbnails
    with_stale_object_retry do
      @community = Community.find(params[:id])
      authorize! :update_thumbnails, @community
      return head(:not_found) if @community.nil?

      apply_thumbnail_uris(resource_id: @community.id)
    end

    @community = Community.find(@community.id).decorate
    render :show
  end

  def destroy
    @community = Community.find(params[:id])
    authorize! :destroy, @community
    Atlas.persister.delete(resource: @community)
  end

  def tombstone
    @community = Community.find(params[:id])
    authorize! :tombstone, @community

    if @community.live_children?
      render json:   { error: 'cannot tombstone a non-empty community',
                       code:  'has_live_children' },
             status: :unprocessable_entity and return
    end

    @community.tombstone(by: @nuid)
    @community = Atlas.persister.save(resource: @community).decorate
  end

  def restore
    @community = Community.find(params[:id])
    authorize! :restore, @community
    @community.restore
    @community = Atlas.persister.save(resource: @community).decorate
  end

  private

    # Mirror of WorksController's provenance helpers — see that file for
    # the full rationale. Communities are roots, so there's no parent
    # depositor to inherit; depositor falls back directly to the
    # proxy_uploader.
    def proxy_uploader_nuid
      @on_behalf_of.presence || @current_user&.nuid
    end

    def depositor_nuid
      return params[:depositor] if params[:depositor].present?

      proxy_uploader_nuid
    end

    def binary_update
      file = params[:binary]
      path = file.tempfile.path.presence || file.path
      @community.mods_xml = File.read(path)
      @community = Atlas.persister.save(resource: @community)
    end

    def metadata_update
      # allow for custom noid for testing purposes
      @community.alternate_ids = params[:metadata]['noid'] if Rails.env.test? && params[:metadata]['noid'].present?
      @community.plain_title = params[:metadata]['title'] if params[:metadata]['title'].present?
      @community.plain_description = params[:metadata]['description'] if params[:metadata]['description'].present?
      @community.permissions = params[:metadata]['permissions'] if params[:metadata]['permissions'].present?
      @community = Atlas.persister.save(resource: @community)
      @community.write_preservation_envelope!
    end
end
