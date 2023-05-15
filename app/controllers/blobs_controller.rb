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
    file = params[:binary]
    blob = BlobCreator.call(work_id: params[:work_id],
                            path: (file.tempfile.path.presence || file.path))
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
