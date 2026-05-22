# frozen_string_literal: true

# Collections
class CollectionsController < ApplicationController
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
    @pagination, @collections = paginate_model(Collection)
  end

  def show
    @collection = Collection.find(params[:id])&.decorate
    return head(:not_found) if @collection.nil?

    render :show, status: (@collection.tombstoned ? :gone : :ok)
  end

  def create
    # TODO: XML
    @collection = CollectionCreator.call(parent_id: params[:parent_id])
  end

  def mods
    collection = Collection.find(params[:id])
    return head(:not_found) if collection.nil? || collection.mods.nil?

    @collection = collection.decorate
  end

  def children
    @collection = Collection.find(params[:id])&.decorate
    return head(:not_found) if @collection.nil?
    return render(:show, status: :gone) if @collection.tombstoned

    @children = @collection.filtered_children
  end

  def ancestors
    @collection = Collection.find(params[:id])&.decorate
    return head(:not_found) if @collection.nil?
    return render(:show, status: :gone) if @collection.tombstoned

    @ancestors = @collection.ancestors
  end

  def update
    @collection = Collection.find(params[:id])

    if params[:binary].present?
      binary_update
    elsif params[:metadata].present?
      metadata_update
    end
  end

  def update_thumbnails
    @collection = Collection.find(params[:id])
    return head(:not_found) if @collection.nil?

    apply_delegate_uris(resource_id: @collection.id, mapping: THUMBNAIL_ROLES, source: params)
    @collection = Collection.find(@collection.id).decorate
    render :show
  end

  def destroy
    # TODO: restrict to admin user
    Atlas.persister.delete(resource: Collection.find(params[:id]))
  end

  def tombstone
    @collection = Collection.find(params[:id])

    if @collection.live_children?
      render json: { error: 'cannot tombstone a non-empty collection',
                     code:  'has_live_children' },
             status: :unprocessable_entity and return
    end

    @collection.tombstone(by: @nuid)
    @collection = Atlas.persister.save(resource: @collection).decorate
  end

  def restore
    @collection = Collection.find(params[:id])
    @collection.restore
    @collection = Atlas.persister.save(resource: @collection).decorate
  end

  private

    def binary_update
      file = params[:binary]
      path = file.tempfile.path.presence || file.path
      @collection.mods_xml = File.read(path)
      @collection = Atlas.persister.save(resource: @collection)
    end

    def metadata_update
      # allow for custom noid for testing purposes
      if Rails.env.test?
        @collection.alternate_ids = params[:metadata]['noid'] if params[:metadata]['noid'].present?
      end
      @collection.plain_title = params[:metadata]['title'] if params[:metadata]['title'].present?
      @collection.plain_description = params[:metadata]['description'] if params[:metadata]['description'].present?
      @collection.permissions = params[:metadata]['permissions'] if params[:metadata]['permissions'].present?
      @collection = Atlas.persister.save(resource: @collection)
      @collection.write_preservation_envelope!
    end
end
