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
      expected_digest:   params[:expected_digest],
      path:              (file.tempfile.path.presence || file.path)
    )
    record_idempotency_key!(@blob.noid, Blob)
    audit_add_file(@blob)
  end

  # Append a new revision. Uber-basic versioning: post a new binary, append
  # its file identifier to the Blob (NOID preserved), refresh the head digest.
  # Idempotent on the Idempotency-Key header (same semantics as create): a
  # double-submit of the replace form with the same key returns the existing
  # Blob instead of minting a second OCFL version.
  def update
    authorize! :update, Blob

    if (record = find_idempotency_record(Blob))
      @blob = Blob.find(record.resource_noid)
      return render_idempotent_resource(@blob, view: :update)
    end

    blob = Blob.find(params[:id])
    path = params[:binary].tempfile.path.presence || params[:binary].path
    verify_digest!(path, params[:expected_digest])
    @blob = append_revision(blob, create_file(path, blob).version_id)
    record_idempotency_key!(@blob.noid, Blob)
  end

  # GET /files/:id/versions
  # Reverse-chronological list of the Blob's retained content revisions. Each
  # descriptor carries the OCFL version label, its file identifier, fixity
  # digest, size, and actor attribution correlated from the file audit ledger.
  # Admin-gated like the MODS version list (it exposes edit attribution).
  # Unknown id → 404 (a Blob is a concrete resource, unlike the type-agnostic
  # MODS list which tolerates an unresolvable id).
  def versions
    authorize! :read, AuditEvent
    @blob = Blob.find(params[:id])
    return head(:not_found) if @blob.nil?

    @versions = BinaryVersionHistory.descriptors(blob: @blob)
  end

  # GET /files/:id/versions/:version_id/content
  # Stream the bytes of a prior version, pinned to its OCFL label. Mirrors
  # #content (same send_file/Rack chunking, memory-safe for large files) but
  # resolves through the version history so only listed content revisions are
  # addressable. Unknown id or version → 404.
  def version_content
    authorize! :read, Blob
    blob = Blob.find(params[:id])
    return head(:not_found) if blob.nil?

    file = BinaryVersionHistory.find_file(blob: blob, version_id: params[:version_id])
    return head(:not_found) if file.nil?

    stream_file(blob, file)
  rescue Valkyrie::StorageAdapter::FileNotFound
    head :not_found
  end

  # POST /files/:id/rollback  body: { version_id: 'vN' }
  # Promote a prior version to current by appending its bytes again as a NEW
  # revision (so rollback is itself non-destructive — it becomes vN+1 with the
  # bytes of vN), keeping the Blob NOID. OCFL dedups the identical content, so
  # no bytes are copied; only a new version pointer is cut. Unknown id or
  # version → 404.
  def rollback
    authorize! :update, Blob
    blob = Blob.find(params[:id])
    return head(:not_found) if blob.nil?

    file = BinaryVersionHistory.find_file(blob: blob, version_id: params[:version_id])
    return head(:not_found) if file.nil?

    @blob = append_revision(blob, create_file(file.disk_path.to_s, blob, blob.original_filename).version_id,
                            rolled_back_from: params[:version_id])
    render :update
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

    stream_file(blob, file)
  rescue Valkyrie::StorageAdapter::FileNotFound
    head :not_found
  end

  # GET /files/:id/ancestry
  # Resolve a content Blob to its parent FileSet and parent Work noids —
  # { "file_set": "<noid>", "work": "<noid>" }. The download path
  # (DownloadsController) is keyed only by the blob id, so a consumer recording
  # a download/stream impression against the containing Work resolves it here
  # rather than threading the work noid through the download URL. Reads on the
  # Blob floor (like #content / #show). Unknown id → 404; either ancestor is
  # null when unresolvable (e.g. an orphan blob with no FileSet parent).
  def ancestry
    authorize! :read, Blob
    @blob = Blob.find(params[:id])
    return head(:not_found) if @blob.nil?

    parent = @blob.parent
    @file_set = parent if parent.is_a?(FileSet)
    grandparent = @file_set&.parent
    @work = grandparent if grandparent.is_a?(Work)
  end

  private

    # send_file hands a Pathname to Rack::Files which chunks at the Rack layer,
    # so this is memory-safe for 20GB+ files. Shared by #content (head bytes)
    # and #version_content (a pinned prior version).
    def stream_file(blob, file)
      send_file file.disk_path, type: blob.mime_type, disposition: 'attachment',
                                filename: blob.original_filename
    end

    # Append a freshly-uploaded revision's versioned file identifier to the
    # Blob, refresh the denormalized head digest, persist, and emit the
    # replace_file provenance row. version_id is stored as a plain string so
    # BinaryVersionHistory can correlate it back exactly; rolled_back_from, when
    # present, records which version this revision reinstated. Shared by the
    # PATCH (#update) and rollback (#rollback) paths, which differ only in where
    # the new bytes came from. Returns the saved Blob.
    def append_revision(blob, version_id, rolled_back_from: nil)
      blob.file_identifiers += [version_id]
      blob.digest = recorded_digest(version_id)
      saved = Atlas.persister.save(resource: blob)
      payload = { blob_noid: saved.noid, version_id: version_id.to_s }
      payload[:rolled_back_from] = rolled_back_from if rolled_back_from
      audit_file!(action: 'replace_file', resource: parent_work_of(saved), payload: payload)
      saved
    end

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
