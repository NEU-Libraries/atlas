# frozen_string_literal: true

# Communities
class CommunitiesController < ApplicationController
  include LazyPagination

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
      if params[:metadata]['thumbnail'].present?
        DelegateUpdater.call(
          resource_id: @community.id,
          use:         Role.thumbnail_image.name,
          uri:         params[:metadata]['thumbnail']
        )
      end
      @community.permissions = params[:metadata]['permissions'] if params[:metadata]['permissions'].present?
      @community = Atlas.persister.save(resource: @community)
      @community.write_preservation_envelope!
    end
end
