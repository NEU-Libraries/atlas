# frozen_string_literal: true

# Communities
class CommunitiesController < ApplicationController
  include LazyPagination
  include DelegateUris

  # Container creation is intentionally left off the reject list (Q7 lean):
  # the seed/admin paths that bootstrap Communities + Collections currently
  # run as :system. Once a dedicated container-creation role exists this
  # gate should tighten to match WorksController.
  before_action :reject_system_principal,
                only: %i[update tombstone restore destroy update_thumbnails]

  THUMBNAIL_ROLES = {
    'thumbnail' => Role.thumbnail_image,
    'thumbnail_2x' => Role.thumbnail_image_2x,
    'preview' => Role.preview_image
  }.freeze

  def index
    @pagination, @communities = paginate_model(Community)
  end

  def show
    @community = Community.find(params[:id])&.decorate
    return head(:not_found) if @community.nil?

    render :show, status: (@community.tombstoned ? :gone : :ok)
  end

  def create
    # TODO: XML
    @community = CommunityCreator.call(parent_id: params[:parent_id])
  end

  def mods
    # TODO: support raw XML, in addition to JSON and HTML
    community = Community.find(params[:id])
    return head(:not_found) if community.nil? || community.mods.nil?

    @community = community.decorate
  end

  def children
    @community = Community.find(params[:id])&.decorate
    return head(:not_found) if @community.nil?
    return render(:show, status: :gone) if @community.tombstoned

    @children = @community.filtered_children
  end

  def ancestors
    @community = Community.find(params[:id])&.decorate
    return head(:not_found) if @community.nil?
    return render(:show, status: :gone) if @community.tombstoned

    @ancestors = @community.ancestors
  end

  def update
    @community = Community.find(params[:id])

    if params[:binary].present?
      binary_update
    elsif params[:metadata].present?
      metadata_update
    end
  end

  def update_thumbnails
    @community = Community.find(params[:id])
    return head(:not_found) if @community.nil?

    apply_delegate_uris(resource_id: @community.id, mapping: THUMBNAIL_ROLES, source: params)
    @community = Community.find(@community.id).decorate
    render :show
  end

  def destroy
    # TODO: restrict to admin user
    Atlas.persister.delete(resource: Community.find(params[:id]))
  end

  def tombstone
    @community = Community.find(params[:id])

    if @community.live_children?
      render json: { error: 'cannot tombstone a non-empty community',
                     code:  'has_live_children' },
             status: :unprocessable_entity and return
    end

    @community.tombstone(by: @nuid)
    @community = Atlas.persister.save(resource: @community).decorate
  end

  def restore
    @community = Community.find(params[:id])
    @community.restore
    @community = Atlas.persister.save(resource: @community).decorate
  end

  private

    def binary_update
      file = params[:binary]
      path = file.tempfile.path.presence || file.path
      @community.mods_xml = File.read(path)
      @community = Atlas.persister.save(resource: @community)
    end

    def metadata_update
      # allow for custom noid for testing purposes
      if Rails.env.test?
        @community.alternate_ids = params[:metadata]['noid'] if params[:metadata]['noid'].present?
      end
      @community.plain_title = params[:metadata]['title'] if params[:metadata]['title'].present?
      @community.plain_description = params[:metadata]['description'] if params[:metadata]['description'].present?
      @community.permissions = params[:metadata]['permissions'] if params[:metadata]['permissions'].present?
      @community = Atlas.persister.save(resource: @community)
      @community.write_preservation_envelope!
    end
end
