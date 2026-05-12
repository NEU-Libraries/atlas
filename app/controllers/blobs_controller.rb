# frozen_string_literal: true

# Blobs
class BlobsController < ApplicationController
  include LazyPagination
  include FileHelper
  include TombstoneAware
  include IdempotentCreate
  tombstone_aware_for resource_class: Blob, var: :blob, decorate: false
  idempotent_for      resource_class: Blob, var: :blob, decorate: false

  def index
    @pagination, @blobs = paginate_model(Blob)
  end

  def show
    # @blob set by TombstoneAware before_action
  end

  def create
    file = params[:binary]
    @blob = BlobCreator.call(
      work_id: params[:work_id],
      original_filename: params[:original_filename],
      use: params[:use],
      path: (file.tempfile.path.presence ||
             file.path)
    )
    record_idempotency_key!(@blob.noid)
  end

  def update
    # Uber basic versioning, by appending
    blob = Blob.find(params[:id])
    file = params[:binary]
    path = file.tempfile.path.presence || file.path
    file_id = create_file(path, blob).version_id
    blob.file_identifiers += [file_id]
    @blob = Atlas.persister.save(resource: blob)
  end

  def destroy
    # TODO: restrict to admin user
    blob = Blob.find(params[:id])
    return head(:not_found) if blob.nil?

    parent_fs = blob.parent
    blob_id   = blob.id
    Atlas.persister.delete(resource: blob)

    return unless parent_fs.is_a?(FileSet)

    parent_fs.member_ids -= [blob_id]
    parent_fs = Atlas.persister.save(resource: parent_fs)
    parent_fs.write_preservation_envelope!
    METSRebuilder.call(file_set: parent_fs)
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
