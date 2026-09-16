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
    @blob = Blob.find(params.expect(:id))
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
      path:              file.tempfile.path.presence || file.path
    )
    record_idempotency_key!(@blob.noid, Blob)
    audit_add_file(@blob)
  end

  # Appends a revision, NOID preserved. Idempotent on the Idempotency-Key
  # header, so a double-submit returns the existing Blob rather than minting a
  # second OCFL version.
  def update
    authorize! :update, Blob

    if (record = find_idempotency_record(Blob))
      @blob = Blob.find(record.resource_noid)
      return render_idempotent_resource(@blob, view: :update)
    end

    blob = Blob.find(params.expect(:id))
    return head(:not_found) if blob.nil?

    binary = params.expect(:binary)
    path = binary.tempfile.path.presence || binary.path
    verify_digest!(path, params[:expected_digest])
    @blob = append_revision(blob, create_file(path, blob).version_id, source_path: path)
    record_idempotency_key!(@blob.noid, Blob)
  end

  # Gated by the dedicated :read_versions verb rather than the generic
  # `:read, AuditEvent`, so the devolved-admin tier sees binary history
  # without also opening the generic audit-history index.
  def versions
    authorize! :read_versions, Blob
    @blob = Blob.find(params.expect(:id))
    return head(:not_found) if @blob.nil?

    @versions = BinaryVersionHistory.descriptors(blob: @blob)
  end

  # :read_versions is granted class-wide, so there is no per-Blob decision and
  # nothing is dropped for AUTHORIZATION. Otherwise tolerant like
  # resources#find_many: an id resolving to nothing, or to a non-Blob, is
  # dropped, so the result may be shorter than the input.
  def find_many_versions
    authorize! :read_versions, Blob
    ids = Array(params[:ids]).map(&:to_s).uniq
    blobs = Atlas.query.custom_queries
                 .find_many_by_alternate_identifiers(alternate_identifiers: ids)
                 .grep(Blob)
    @histories = BinaryVersionHistory.descriptors_for_many(blobs: blobs)
  end

  # Resolves through the version history, so only LISTED content revisions are
  # addressable.
  def version_content
    blob = Blob.find(params.expect(:id))
    authorize! :read, blob || Blob
    return head(:not_found) if blob.nil?

    file = BinaryVersionHistory.find_file(blob: blob, version_id: params[:version_id])
    return head(:not_found) if file.nil?

    stream_file(blob, file)
  rescue Valkyrie::StorageAdapter::FileNotFound
    head :not_found
  end

  # Non-destructive: vN's bytes are appended as vN+1. OCFL dedups the
  # identical content, so no bytes are copied -- only a pointer is cut.
  def rollback
    authorize! :update, Blob
    blob = Blob.find(params.expect(:id))
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
    blob = Blob.find(params.expect(:id))
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

  # send_file hands a Pathname to Rack::Files, which chunks at the Rack layer,
  # so this is memory-safe for 20GB+ files.
  # TODO: once nginx fronts Atlas, un-comment the X-Accel-Redirect line in
  # config/environments/production.rb so nginx serves bytes natively.
  def content
    blob = Blob.find(params.expect(:id))
    authorize! :read, blob || Blob
    return head(:not_found) if blob.nil?

    file = blob.file
    return head(:not_found) if file.nil?

    serve_bytes(blob, file)
  rescue Valkyrie::StorageAdapter::FileNotFound
    head :not_found
  end

  # The download path is keyed only by the blob id, so a consumer recording an
  # impression against the containing Work resolves it here rather than
  # threading the work noid through the download URL. Either ancestor is null
  # when unresolvable.
  def ancestry
    @blob = Blob.find(params.expect(:id))
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

    # Range support exists so a browser media element can seek. Multi-range is
    # unsupported -- a single range is all one needs. The slice streams in
    # chunks via FileSlice, never buffered. See docs/binaries.md for the
    # status matrix.
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

    # nil for an absent or non-single-`bytes=` range, which RFC 7233 lets us
    # ignore and serve a full 200. :unsatisfiable is a valid-but-out-of-bounds
    # range (416).
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

    # version_id is stored as a plain string so BinaryVersionHistory can
    # correlate it back EXACTLY. Shared by the PATCH and rollback paths, which
    # differ only in where the bytes came from.
    def append_revision(blob, version_id, source_path:, rolled_back_from: nil)
      blob.file_identifiers += [version_id]
      refresh_head_facts(blob, version_id, source_path)
      saved = Atlas.persister.save(resource: blob)
      payload = { blob_noid: saved.noid, version_id: version_id.to_s }
      payload[:rolled_back_from] = rolled_back_from if rolled_back_from
      audit_file!(action: 'replace_file', resource: parent_work_of(saved), payload: payload)
      saved
    end

    # These three are a read-path cache over the storage layer, so a new
    # revision MUST re-derive all three: a stale size is what a consumer sets
    # Content-Length and its Range arithmetic from, and a replaced audio file
    # would truncate mid-stream.
    #
    # The MIME hint is the DEPOSITED filename, not the upload's own staged temp
    # path -- Marcel answers application/octet-stream for `up.tmp` where
    # `data.csv` answers text/csv. Magic bytes still win over the hint.
    #
    # original_filename, use and label stay as deposited. label especially:
    # re-deriving it would relabel a replaced derivative tier back to Master.
    def refresh_head_facts(blob, version_id, source_path)
      blob.digest    = recorded_digest(version_id)
      blob.size      = ::File.size(source_path)
      blob.mime_type = mime_type(source_path, name: blob.original_filename)
    end

    # RESOURCE_TYPES admits no Blob or FileSet, so a file event hangs off the
    # parent Work and the blob identity rides in note/payload. An orphan blob
    # is skipped rather than writing a row with no resource.
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
