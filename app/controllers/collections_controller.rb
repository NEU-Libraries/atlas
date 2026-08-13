# frozen_string_literal: true

# Collections
# rubocop:disable Metrics/ClassLength
class CollectionsController < ApplicationController
  include LazyPagination
  include DelegateUris
  include StaleObjectRetry
  include Reparentable
  include Auditable
  include ParentScopedCreate

  # Container creation is intentionally left open to :system so the seed task
  # can bootstrap Communities + Collections. The :system carve-out for :create
  # lives in Ability#apply_role_abilities; it can be retired once a dedicated
  # container-creation role exists.

  def index
    authorize! :read, Collection
    @pagination, @collections = paginate_model(Collection)
  end

  def show
    authorize! :read, Collection
    @collection = find_collection(params[:id])&.decorate
    return head(:not_found) if @collection.nil?

    render :show, status: (@collection.tombstoned ? :gone : :ok)
  end

  # A Collection always has a parent, so a blank or unresolvable parent_id is
  # a 404 rather than a create with no home.
  def create
    authorize! :create, Collection
    parent = authorized_create_parent(params[:parent_id])
    return head(:not_found) if parent.nil?

    # TODO: XML
    @collection = CollectionCreator.call(
      parent_id:         parent.noid,
      featured:          featured_param,
      proxy_uploader:    proxy_uploader_nuid,
      depositor:         depositor_nuid,
      actor_nuid:        @current_user&.nuid,
      on_behalf_of_nuid: @on_behalf_of
    )
  end

  def mods
    authorize! :read, Collection
    collection = find_collection(params[:id])
    return head(:not_found) if collection.nil? || collection.mods.nil?

    @collection = collection.decorate
  end

  def children
    authorize! :read, Collection
    @collection = find_collection(params[:id])&.decorate
    return head(:not_found) if @collection.nil?
    return render(:show, status: :gone) if @collection.tombstoned

    @children = @collection.filtered_children
  end

  def ancestors
    authorize! :read, Collection
    @collection = find_collection(params[:id])&.decorate
    return head(:not_found) if @collection.nil?
    return render(:show, status: :gone) if @collection.tombstoned

    @ancestors = @collection.ancestors
  end

  def update
    @collection = find_collection(params[:id])
    authorize! :update, @collection
    return head(:not_found) if @collection.nil?

    if params[:binary].present?
      binary_update
    elsif params[:metadata].present?
      metadata_update
    elsif params.key?('featured')
      featured_update
    end
  end

  def update_thumbnails
    with_stale_object_retry do
      @collection = find_collection(params[:id])
      authorize! :update_thumbnails, @collection
      return head(:not_found) if @collection.nil?

      apply_thumbnail_uris(resource_id: @collection.id)
    end

    @collection = Collection.find(@collection.id).decorate
    render :show
  end

  # Irreversible, and unlike tombstone it also refuses a member that is merely
  # tombstoned: a purge cannot be undone, so a member left behind here is
  # orphaned for good. An operator empties the tree leaf-first instead.
  def destroy
    @collection = find_collection(params[:id])
    authorize! :destroy, @collection
    return head(:not_found) if @collection.nil?

    if @collection.filtered_children.any?
      render json:   { error: 'cannot destroy a collection that still has members',
                       code:  'has_children' },
             status: :unprocessable_entity and return
    end

    ResourcePurger.call(resource: @collection, actor_nuid: @current_user&.nuid,
                        on_behalf_of_nuid: @on_behalf_of)
  end

  def tombstone
    @collection = find_collection(params[:id])
    authorize! :tombstone, @collection
    return head(:not_found) if @collection.nil?

    if @collection.live_children?
      render json:   { error: 'cannot tombstone a non-empty collection',
                       code:  'has_live_children' },
             status: :unprocessable_entity and return
    end

    @collection.tombstone(by: @current_user&.nuid)
    @collection = Atlas.persister.save(resource: @collection).decorate
    audit!(resource: @collection, action: 'tombstone', change_type: 'lifecycle')
  end

  def restore
    @collection = find_collection(params[:id])
    authorize! :restore, @collection
    return head(:not_found) if @collection.nil?

    @collection.restore
    @collection = Atlas.persister.save(resource: @collection).decorate
    audit!(resource: @collection, action: 'restore', change_type: 'lifecycle')
  end

  # Move a Collection under a different Community or Collection. Validates +
  # re-projects the moved subtree's descendant collections (Reparentable).
  def update_parent
    reparent(Collection)
  end

  private

    # Resolve :id to a Collection, or nil if the id is absent OR names a
    # resource of another type. Valkyrie's `Collection.find` is not
    # type-scoped, so a hand-edited /collections/<work-id> would otherwise feed
    # a non-Collection into the Collection serializer and 500. Collapsing a
    # wrong-type id to nil keeps the endpoint's type contract: it 404s exactly
    # like an unknown id. (Mirrors WorksController#find_work.)
    def find_collection(id)
      collection = Collection.find(id)
      collection if collection.is_a?(Collection)
    end

    # Mirror of WorksController's provenance helpers — see that file for
    # the full rationale. Collections don't have a parent-default
    # inheritance path (Communities aren't normally configured as
    # depositor-bearing batch sources), so depositor falls back directly
    # to the proxy_uploader.
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
      @collection.mods_xml = File.read(path)
      @collection = Atlas.persister.save(resource: @collection)
      audit!(resource: @collection, action: 'update', change_type: 'metadata', payload: { source: 'mods' })
    end

    def metadata_update
      @collection = audited_metadata_update(@collection)
    end

    # Toggle the showcase "Featured" flag. A resource-attribute write (not
    # MODS), so it bypasses the descriptive-metadata path; @collection is
    # already found + authorized in #update, and the view auto-decorates.
    def featured_update
      @collection.featured = featured_param
      @collection = Atlas.persister.save(resource: @collection)
      audit!(resource: @collection, action: 'update', change_type: 'metadata',
             payload: { featured: @collection.featured })
    end

    # Coerce the wire value ("true"/"false"/absent) to a real Boolean,
    # defaulting to false so a create without the param is not featured.
    def featured_param
      ActiveModel::Type::Boolean.new.cast(params[:featured]) || false
    end
end
# rubocop:enable Metrics/ClassLength
