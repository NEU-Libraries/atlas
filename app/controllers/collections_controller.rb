# frozen_string_literal: true

# Collections
class CollectionsController < ApplicationController
  include LazyPagination
  include Auditable
  include CachedResponses
  include ParentScopedCreate

  # Container creation is intentionally left open to :system so the seed task
  # can bootstrap Communities + Collections. The :system carve-out for :create
  # lives in Ability#apply_role_abilities; it can be retired once a dedicated
  # container-creation role exists.

  # The unfiltered roll of every Collection. :index_all is admin-only (via the
  # manage :all wildcard) for the same reason as WorksController#index — a
  # paginated list cannot honour the per-resource read gate row by row.
  def index
    authorize! :index_all, Collection
    @pagination, @collections = paginate_model(Collection)
    MODSPreloader.call(resources: @collections)
  end

  def show
    resource = find_collection(params[:id])
    authorize! :read, resource || Collection
    return head(:not_found) if resource.nil?

    cached_render('collections.show', resource) do
      @collection = resource.decorate

      render :show, status: (@collection.tombstoned ? :gone : :ok)
    end
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
    collection = find_collection(params[:id])
    authorize! :read, collection || Collection
    return head(:not_found) if collection.nil? || collection.mods.nil?

    cached_render(format_scope('collections.mods'), collection) do
      @collection = collection.decorate
      render :mods
    end
  end

  # Toggle the showcase "Featured" flag -- a resource-attribute write, not
  # MODS and not the ACL, so it has its own path rather than a third payload
  # shape on a shared one.
  def update_featured
    resource = find_collection(params[:id])
    authorize! :update, resource || Collection
    return head(:not_found) if resource.nil?

    resource.featured = featured_param
    @collection = Atlas.persister.save(resource: resource).decorate
    audit!(resource: @collection, action: 'update', change_type: 'metadata',
           payload: { featured: @collection.featured })
    render :show
  end

  # Child NOIDs, filtered to the ones this caller may read. A public container
  # can hold a restricted child, and listing that child's NOID here would hand
  # back the id the gated single-resource route refuses to serve.
  def children
    resource = find_collection(params[:id])
    authorize! :read, resource || Collection
    return head(:not_found) if resource.nil?

    @collection = resource.decorate
    return render(:show, status: :gone) if @collection.tombstoned

    @children = readable(@collection.filtered_child_resources).map { |child| child.noid.to_s }
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

    # Coerce the wire value ("true"/"false"/absent) to a real Boolean,
    # defaulting to false so a create without the param is not featured.
    def featured_param
      ActiveModel::Type::Boolean.new.cast(params[:featured]) || false
    end
end
