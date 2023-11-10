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
    @collection = Collection.find(params[:id]).decorate
  end

  def children
    @children = Community.find(params[:id]).filtered_children
  end

  def update
    collection = Collection.find(params[:id])

    file = params[:binary]
    path = file.tempfile.path.presence || file.path
    collection.mods_xml = File.read(path)
    @collection = Atlas.persister.save(resource: collection)
  end

  def destroy
    # TODO: restrict to admin user
    Atlas.persister.delete(resource: Collection.find(params[:id]))
  end
end
