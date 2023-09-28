# frozen_string_literal: true

# Blobs
class BlobsController < ApplicationController
  include LazyPagination
  include FileHelper

  def index
    @pagination, @blobs = paginate_model(Blob)
  end

  def show
    @blob = Blob.find(params[:id])
  end

  def create
    file = params[:binary]
    @blob = BlobCreator.call(
      work_id: params[:work_id],
      path: (file.tempfile.path.presence ||
             file.path)
    )
  end

  def update
    # Uber basic versioning, by appending
    blob = Blob.find(params[:id])
    file = params[:binary]
    path = file.tempfile.path.presence || file.path
    file_id = create_file(path, blob).id
    blob.file_identifiers += [file_id]
    @blob = Atlas.persister.save(resource: blob)
  end

  def destroy
    # TODO: restrict to admin user
    Atlas.persister.delete(resource: Blob.find(params[:id]))
  end
end
