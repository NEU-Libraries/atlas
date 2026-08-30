# frozen_string_literal: true

# Blobs
class BlobsController < ApplicationController
  include LazyPagination
  include FileHelper
  include MimeHelper
  include IdempotentCreate
  include Auditable

  # The unfiltered roll of every Blob. :index_all is admin-only (via the
  # manage :all wildcard) for the same reason as WorksController#index — a
  # paginated list cannot honour the per-resource read gate row by row.
  def index
    authorize! :index_all, Blob
    @pagination, @blobs = paginate_model(Blob)
  end

  def show
    @blob = Blob.find(params[:id])
    authorize! :read, @blob || Blob
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
  # its file identifier to the Blob (NOID preserved), refresh the head-revision
  # facts (see #refresh_head_facts). Idempotent on the Idempotency-Key header
  # (same semantics as create): a double-submit of the replace form with the
  # same key returns the existing Blob instead of minting a second OCFL version.
  # Unknown id → 404.
  def update
    authorize! :update, Blob

    if (record = find_idempotency_record(Blob))
      @blob = Blob.find(record.resource_noid)
      return render_idempotent_resource(@blob, view: :update)
    end

    blob = Blob.find(params[:id])
    return head(:not_found) if blob.nil?

    path = params[:binary].tempfile.path.presence || params[:binary].path
    verify_digest!(path, params[:expected_digest])
    @blob = append_revision(blob, create_file(path, blob).version_id, source_path: path)
    record_idempotency_key!(@blob.noid, Blob)
  end

  # GET /files/:id/versions
  # Reverse-chronological list of the Blob's retained content revisions. Each
  # descriptor carries the OCFL version label, its file identifier, fixity
  # digest, size, and actor attribution correlated from the file audit ledger.
  # Admin-gated like the MODS version list (it exposes edit attribution) —
  # via the dedicated :read_versions verb (not the generic `:read, AuditEvent`
  # the audit-history tab uses), so the devolved-admin tier can see this
  # without also opening the generic audit-history index. Unknown id → 404
  # (a Blob is a concrete resource, unlike the type-agnostic MODS list which
  # tolerates an unresolvable id).
  def versions
    authorize! :read_versions, Blob
    @blob = Blob.find(params[:id])
    return head(:not_found) if @blob.nil?

    @versions = BinaryVersionHistory.descriptors(blob: @blob)
  end

  # POST /files/find_many_versions  body: { ids: [<noid>, …] }
  # The batched counterpart to #versions: version history for many Blobs in one
  # round-trip, for a caller holding a set of Blob noids. The admin file-manage
  # listing is the motivating one — it reads every replaceable Blob on a Work,
  # which on a multipage Work is one request per page binary.
  #
  # Same gate as #versions: the descriptors carry the same edit attribution, and
  # :read_versions is granted class-wide, so there is no per-Blob decision to
  # make and nothing is dropped for authorization. Tolerant like
  # resources#find_many otherwise — an id resolving to nothing, or to a resource
  # that is not a Blob, is dropped rather than raised on, so the result may be
  # shorter than the input. Callers index by blob_id.
  def find_many_versions
    authorize! :read_versions, Blob
    ids = Array(params[:ids]).map(&:to_s).uniq
    blobs = Atlas.query.custom_queries
                 .find_many_by_alternate_identifiers(alternate_identifiers: ids)
                 .select { |resource| resource.is_a?(Blob) }
    @histories = BinaryVersionHistory.descriptors_for_many(blobs: blobs)
  end

  # GET /files/:id/versions/:version_id/content
  # Stream the bytes of a prior version, pinned to its OCFL label. Mirrors
  # #content (same send_file/Rack chunking, memory-safe for large files) but
  # resolves through the version history so only listed content revisions are
  # addressable. Unknown id or version → 404.
  def version_content
    blob = Blob.find(params[:id])
    authorize! :read, blob || Blob
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

    source_path = file.disk_path.to_s
    @blob = append_revision(blob, create_file(source_path, blob, blob.original_filename).version_id,
                            source_path: source_path, rolled_back_from: params[:version_id])
    render :update
  end

  def destroy
    authorize! :destroy, Blob
    blob = Blob.find(params[:id])
    return head(:not_found) if blob.nil?

    parent_fs = blob.parent
    blob_id   = blob.id
    # Irreversible: takes the OCFL object with it, so every retained revision
    # of these bytes goes too, not just the head.
    ResourcePurger.call(resource: blob)

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
  # so this is memory-safe for 20GB+ files. Honours an HTTP Range request so a
  # browser media element can seek (see #serve_bytes). Once nginx fronts Atlas,
  # un-comment the X-Accel-Redirect line in config/environments/production.rb
  # so nginx handles byte-serving — and Range — natively.
  def content
    blob = Blob.find(params[:id])
    authorize! :read, blob || Blob
    return head(:not_found) if blob.nil?

    file = blob.file
    return head(:not_found) if file.nil?

    serve_bytes(blob, file)
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
    @blob = Blob.find(params[:id])
    authorize! :read, @blob || Blob
    return head(:not_found) if @blob.nil?

    parent = @blob.parent
    @file_set = parent if parent.is_a?(FileSet)
    grandparent = @file_set&.parent
    @work = grandparent if grandparent.is_a?(Work)
  end

  private

    # send_file hands a Pathname to Rack::Files which chunks at the Rack layer,
    # so this is memory-safe for 20GB+ files. Used by #version_content (a pinned
    # prior version); #content goes through #serve_bytes for Range support.
    def stream_file(blob, file)
      send_file file.disk_path, type: blob.mime_type, disposition: 'attachment',
                                filename: blob.original_filename
    end

    # Byte-serve a Blob's current content with HTTP Range support, so a browser
    # media element can seek (it issues `Range: bytes=…` and expects a `206
    # Partial Content` it can scrub over). Always advertises `Accept-Ranges:
    # bytes`; serves the whole body as `200` when no (or an unparseable) Range
    # is present, a single byte range as `206` + `Content-Range`, and a valid-
    # but-out-of-bounds range as `416`. Multi-range is unsupported — a single
    # range is all media elements need. Memory-safe: the slice is streamed in
    # chunks via FileSlice, never buffered.
    def serve_bytes(blob, file)
      path  = file.disk_path
      total = ::File.size(path)
      response.set_header('Accept-Ranges', 'bytes')

      range = parse_byte_range(request.get_header('HTTP_RANGE'), total)
      return stream_file(blob, file) if range.nil?

      if range == :unsatisfiable
        response.set_header('Content-Range', "bytes */#{total}")
        return head(:range_not_satisfiable)
      end

      send_byte_range(blob, path, range, total)
    end

    # Stream a single inclusive [first, last] byte range as 206 Partial Content.
    # Content-Length is set explicitly to the slice size (Rails does not derive
    # it for a streamed body) and Last-Modified is set so Rack::ETag skips
    # buffering the body to digest it — keeping the partial response streamed.
    def send_byte_range(blob, path, range, total)
      first, last = range
      response.status = 206
      response.set_header('Content-Range', "bytes #{first}-#{last}/#{total}")
      response.set_header('Content-Length', (last - first + 1).to_s)
      response.set_header('Last-Modified', ::File.mtime(path).httpdate)
      response.content_type = blob.mime_type
      response.set_header('Content-Disposition',
                          ActionDispatch::Http::ContentDisposition.format(
                            disposition: 'attachment', filename: blob.original_filename
                          ))
      self.response_body = FileSlice.new(path, first, last - first + 1)
    end

    # Parse a single HTTP byte range against the resource size. Returns nil when
    # no Range header is present or it is not a single `bytes=` range (RFC 7233:
    # ignore and serve the full 200 body — covers multi-range and other units),
    # a `[first, last]` inclusive pair when satisfiable, or :unsatisfiable for a
    # syntactically-valid but out-of-bounds range (416).
    def parse_byte_range(header, total)
      return nil if header.blank?

      match = /\Abytes=(\d*)-(\d*)\z/.match(header)
      return nil unless match

      match[1].empty? ? suffix_range(match[2], total) : explicit_range(match[1], match[2], total)
    end

    # `bytes=-N` — the final N bytes. An empty/zero suffix is unsatisfiable.
    def suffix_range(end_str, total)
      suffix = end_str.to_i
      return :unsatisfiable if end_str.empty? || suffix.zero?

      [[total - suffix, 0].max, total - 1]
    end

    # `bytes=START-` / `bytes=START-END` — clamp END to the last byte; a start
    # past the last byte (or START > END) is unsatisfiable.
    def explicit_range(start_str, end_str, total)
      first = start_str.to_i
      last  = end_str.empty? ? total - 1 : [end_str.to_i, total - 1].min
      return :unsatisfiable if first > last || first >= total

      [first, last]
    end

    # Append a freshly-uploaded revision's versioned file identifier to the
    # Blob, refresh the denormalized head-revision facts, persist, and emit the
    # replace_file provenance row. version_id is stored as a plain string so
    # BinaryVersionHistory can correlate it back exactly; rolled_back_from, when
    # present, records which version this revision reinstated. Shared by the
    # PATCH (#update) and rollback (#rollback) paths, which differ only in where
    # the new bytes came from — source_path is those bytes on disk. Returns the
    # saved Blob.
    def append_revision(blob, version_id, source_path:, rolled_back_from: nil)
      blob.file_identifiers += [version_id]
      refresh_head_facts(blob, version_id, source_path)
      saved = Atlas.persister.save(resource: blob)
      payload = { blob_noid: saved.noid, version_id: version_id.to_s }
      payload[:rolled_back_from] = rolled_back_from if rolled_back_from
      audit_file!(action: 'replace_file', resource: parent_work_of(saved), payload: payload)
      saved
    end

    # digest, size and mime_type describe the bytes that are *currently* head,
    # so a new revision has to re-derive all three from those bytes — they are a
    # read-path cache over the storage layer, and a stale size is what a
    # consumer sets Content-Length and its Range arithmetic from (a replaced
    # audio file would then truncate mid-stream).
    #
    # The MIME name hint is the deposited original_filename, not the replacing
    # upload's own name, which is often a staged temp path: Marcel needs a real
    # extension for formats with weak magic bytes, and `up.tmp` makes it answer
    # application/octet-stream where `data.csv` answers text/csv. Magic bytes
    # still win over the hint, so a genuine format change is still detected.
    #
    # original_filename, use and label stay as deposited. label especially:
    # re-deriving it from bytes would relabel any replaced derivative tier
    # (Small Image, Medium Image) back to Master Image.
    def refresh_head_facts(blob, version_id, source_path)
      blob.digest    = recorded_digest(version_id)
      blob.size      = ::File.size(source_path)
      blob.mime_type = mime_type(source_path, name: blob.original_filename)
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
