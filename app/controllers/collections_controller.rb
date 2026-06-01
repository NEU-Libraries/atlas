# frozen_string_literal: true

# Collections
class CollectionsController < ApplicationController
  include LazyPagination
  include DelegateUris
  include StaleObjectRetry
  include Reparentable

  # Container creation is intentionally left open to :system (Q7 lean) so the
  # seed task can bootstrap Communities + Collections. The :system carve-out
  # for :create lives in Ability#apply_role_abilities; once a dedicated
  # container-creation role exists, that carve-out goes away.

  def index
    authorize! :read, Collection
    @pagination, @collections = paginate_model(Collection)
  end

  def show
    authorize! :read, Collection
    @collection = Collection.find(params[:id])&.decorate
    return head(:not_found) if @collection.nil?

    render :show, status: (@collection.tombstoned ? :gone : :ok)
  end

  def create
    authorize! :create, Collection
    # TODO: XML
    @collection = CollectionCreator.call(
      parent_id:         params[:parent_id],
      proxy_uploader:    proxy_uploader_nuid,
      depositor:         depositor_nuid,
      actor_nuid:        @current_user&.nuid,
      on_behalf_of_nuid: @on_behalf_of
    )
  end

  def mods
    authorize! :read, Collection
    collection = Collection.find(params[:id])
    return head(:not_found) if collection.nil? || collection.mods.nil?

    @collection = collection.decorate
  end

  def children
    authorize! :read, Collection
    @collection = Collection.find(params[:id])&.decorate
    return head(:not_found) if @collection.nil?
    return render(:show, status: :gone) if @collection.tombstoned

    @children = @collection.filtered_children
  end

  def ancestors
    authorize! :read, Collection
    @collection = Collection.find(params[:id])&.decorate
    return head(:not_found) if @collection.nil?
    return render(:show, status: :gone) if @collection.tombstoned

    @ancestors = @collection.ancestors
  end

  def update
    @collection = Collection.find(params[:id])
    authorize! :update, @collection

    if params[:binary].present?
      binary_update
    elsif params[:metadata].present?
      metadata_update
    end
  end

  def update_thumbnails
    with_stale_object_retry do
      @collection = Collection.find(params[:id])
      authorize! :update_thumbnails, @collection
      return head(:not_found) if @collection.nil?

      apply_thumbnail_uris(resource_id: @collection.id)
    end

    @collection = Collection.find(@collection.id).decorate
    render :show
  end

  def destroy
    @collection = Collection.find(params[:id])
    authorize! :destroy, @collection
    Atlas.persister.delete(resource: @collection)
  end

  def tombstone
    @collection = Collection.find(params[:id])
    authorize! :tombstone, @collection

    if @collection.live_children?
      render json:   { error: 'cannot tombstone a non-empty collection',
                       code:  'has_live_children' },
             status: :unprocessable_entity and return
    end

    @collection.tombstone(by: @nuid)
    @collection = Atlas.persister.save(resource: @collection).decorate
  end

  def restore
    @collection = Collection.find(params[:id])
    authorize! :restore, @collection
    @collection.restore
    @collection = Atlas.persister.save(resource: @collection).decorate
  end

  # Move a Collection under a different Community or Collection. Validates +
  # re-projects the moved subtree's descendant collections (Reparentable).
  def update_parent
    reparent(Collection)
  end

  private

    # Mirror of WorksController's provenance helpers — see that file for
    # the full rationale. Collections don't have a parent-default
    # inheritance path (Communities aren't normally configured as
    # depositor-bearing batch sources), so depositor falls back directly
    # to the proxy_uploader.
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
      @collection.mods_xml = File.read(path)
      @collection = Atlas.persister.save(resource: @collection)
    end

    def metadata_update
      # allow for custom noid for testing purposes
      @collection.alternate_ids = params[:metadata]['noid'] if Rails.env.test? && params[:metadata]['noid'].present?
      @collection.plain_title = params[:metadata]['title'] if params[:metadata]['title'].present?
      @collection.plain_description = params[:metadata]['description'] if params[:metadata]['description'].present?
      @collection.permissions = params[:metadata]['permissions'] if params[:metadata]['permissions'].present?
      @collection = Atlas.persister.save(resource: @collection)
      @collection.write_preservation_envelope!
    end
end
