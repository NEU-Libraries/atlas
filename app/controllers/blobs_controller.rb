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
      original_filename: params[:original_filename],
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

  # GET /files/:id/content
  # send_file hands a Pathname to Rack::Files which chunks at the Rack layer,
  # so this is memory-safe for 20GB+ files. Once nginx fronts Atlas, un-comment
  # the X-Accel-Redirect line in config/environments/production.rb so nginx
  # handles byte-serving natively.
  def content
    blob = Blob.find(params[:id])
    return head(:not_found) if blob.nil?

    file = blob.file
    return head(:not_found) if file.nil?

    send_file file.disk_path,
              type: blob.mime_type,
              disposition: 'attachment',
              filename: blob.original_filename
  rescue Valkyrie::StorageAdapter::FileNotFound
    head :not_found
  end
end
