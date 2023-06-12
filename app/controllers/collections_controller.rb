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
    CollectionCreator.call
  end

  def mods
    @collection = Collection.find(params[:id]).decorate
  end

  def update
    collection = Collection.find(params[:id])
    collection.mods_xml = parse_xml
  end

  def destroy
    # TODO: restrict to admin user
    Atlas.persister.delete(resource: Collection.find(params[:id]))
  end
end
