# frozen_string_literal: true

# Blobs
class BlobsController < ApplicationController
  include LazyPagination
  include FileHelper
  include IdempotentCreate
  include Auditable

  def index
    authorize! :read, Blob
    @pagination, @blobs = paginate_model(Blob)
  end

  def show
    authorize! :read, Blob
    @blob = Blob.find(params[:id])
    return head(:not_found) if @blob.nil?

    render :show, status: (@blob.tombstoned ? :gone : :ok)
  end

  def create
    authorize! :create, Blob

    if (record = find_idempotency_record(Blob))
      @blob = Blob.find(record.resource_noid)
      return render_idempotent_resource(@blob)
    end

    file = params[:binary]
    @blob = BlobCreator.call(
      work_id:           params[:work_id],
      original_filename: params[:original_filename],
      use:               params[:use],
      path:              (file.tempfile.path.presence ||
             file.path)
    )
    record_idempotency_key!(@blob.noid, Blob)
    audit_add_file(@blob)
  end

  def update
    authorize! :update, Blob
    # Uber basic versioning, by appending
    blob = Blob.find(params[:id])
    file = params[:binary]
    path = file.tempfile.path.presence || file.path
    file_id = create_file(path, blob).version_id
    blob.file_identifiers += [file_id]
    @blob = Atlas.persister.save(resource: blob)
    audit_file!(action: 'replace_file', resource: parent_work_of(@blob),
                payload: { blob_noid: @blob.noid, version_id: file_id })
  end

  def destroy
    authorize! :destroy, Blob
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

    # The Blob is gone, so hang the event off the parent Work (file events use
    # RESOURCE_TYPES = Work); the removed blob is recorded in the payload.
    audit_file!(action: 'remove_file', resource: parent_fs.parent,
                payload: { blob_noid: blob.noid })
  end

  # GET /files/:id/content
  # send_file hands a Pathname to Rack::Files which chunks at the Rack layer,
  # so this is memory-safe for 20GB+ files. Once nginx fronts Atlas, un-comment
  # the X-Accel-Redirect line in config/environments/production.rb so nginx
  # handles byte-serving natively.
  def content
    authorize! :read, Blob
    blob = Blob.find(params[:id])
    return head(:not_found) if blob.nil?

    file = blob.file
    return head(:not_found) if file.nil?

    send_file file.disk_path,
              type:        blob.mime_type,
              disposition: 'attachment',
              filename:    blob.original_filename
  rescue Valkyrie::StorageAdapter::FileNotFound
    head :not_found
  end

  private

    # File events carry change_type 'file', which is resource-scoped — but
    # RESOURCE_TYPES only admits Community/Collection/Work, and there is no
    # per-Blob/FileSet audit row. So a file event hangs off the parent Work;
    # if one can't be resolved (orphan blob), skip rather than write a row
    # with no resource. `note`/`payload` carry the blob identity.
    def audit_file!(action:, resource:, payload:)
      return unless resource.is_a?(Work)

      audit!(resource: resource, action: action, change_type: 'file', payload: payload)
    end

    def audit_add_file(blob)
      audit_file!(action: 'add_file', resource: parent_work_of(blob),
                  payload: { blob_noid: blob.noid, filename: blob.original_filename, use: blob.use })
    end

    # Walk Blob → FileSet → Work. Accepts a Blob or a FileSet.
    def parent_work_of(resource)
      file_set = resource.is_a?(FileSet) ? resource : resource&.parent
      file_set&.parent
    end
end
