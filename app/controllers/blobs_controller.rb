# frozen_string_literal: true

# Blobs
class BlobsController < ApplicationController
  include LazyPagination

  def index
    @pagination, @blobs = paginate_model(Blob)
  end
  def show
    @blob = Blob.find(params[:id])
  end
  def create
    # TODO: Needs work id
    # TODO: Needs path
    blob = BlobCreator.call()
  end
  def mods
    @blob = Blob.find(params[:id])
  end
  def update
    blob = Blob.find(params[:id])
  end
  def destroy
    # TODO: restrict to admin user
    Atlas.persister.delete(resource: Blob.find(params[:id]))
  end
end
