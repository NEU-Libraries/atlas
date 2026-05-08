# frozen_string_literal: true

# Collections
class CollectionsController < ApplicationController
  include LazyPagination

  def index
    @pagination, @collections = paginate_model(Collection)
  end

  def show
    @collection = Collection.find(params[:id]).decorate
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
    @children = Collection.find(params[:id]).filtered_children
  end

  def ancestors
    @ancestors = Collection.find(params[:id]).ancestors
  end

  def update
    @collection = Collection.find(params[:id])

    if params[:binary].present?
      binary_update
    elsif params[:metadata].present?
      metadata_update
    end
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

    @collection.tombstoned    = true
    @collection.tombstoned_at = Time.current
    @collection.tombstoned_by = @nuid
    @collection = Atlas.persister.save(resource: @collection).decorate
  end

  def restore
    @collection = Collection.find(params[:id])
    @collection.tombstoned    = false
    @collection.tombstoned_at = nil
    @collection.tombstoned_by = nil
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
      @collection.safe_thumbnail = params[:metadata]['thumbnail'] if params[:metadata]['thumbnail'].present?
      @collection.permissions = params[:metadata]['permissions'] if params[:metadata]['permissions'].present?
      @collection = Atlas.persister.save(resource: @collection)
      @collection.write_preservation_envelope!
    end
end
