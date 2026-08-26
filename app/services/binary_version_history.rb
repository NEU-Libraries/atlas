# frozen_string_literal: true

# Assembles a Blob's binary version history from the OCFL storage layer.
#
# Read-only and entirely derived — it mints no storage and mutates nothing.
# This is the binary counterpart to MODSVersionHistory, but its source of
# truth is different and simpler: the Blob's ordered `file_identifiers` IS the
# authoritative list of content revisions. BlobCreator seeds the first entry,
# every PATCH /files/:id (and POST /files/:id/rollback) appends exactly one,
# and each entry is the versioned OCFL id (…/vN/<logical-path>) of the bytes
# written for that revision.
#
# So we list straight off that array — no OCFL version scan and, crucially, no
# digest coalescing. MODSVersionHistory has to collapse byte-identical runs
# because it can't tell a descMetadata edit from an envelope-only bump that
# carries the same bytes forward; here the Blob already records precisely which
# OCFL versions were content writes, so envelope bumps (properties.json /
# permissions.json) never appear and a genuine re-upload of identical bytes is
# still its own listed revision.
#
# Per-version provenance (created, digest, size) comes from the OCFL layer;
# actor attribution is correlated from the file AuditEvents hung off the parent
# Work — matched *exactly* by the version id the replace event recorded (the
# seed revision resolves to the add_file event by blob NOID), so unlike the
# MODS timestamp-proximity correlation there is no window to tune.
class BinaryVersionHistory
  def self.descriptors(blob:, file_events: nil)
    new(blob, file_events: file_events).descriptors
  end

  def self.find_file(blob:, version_id:)
    new(blob).find_file(version_id)
  end

  # Descriptors for many Blobs at once, keyed by NOID — the batched sibling of
  # .descriptors, for the batch read endpoint.
  #
  # Attribution is what makes this worth batching: correlating one Blob's
  # revisions walks Blob -> FileSet -> Work and then reads that Work's file
  # ledger, so a per-Blob loop costs several queries per Blob. Here both graph
  # hops go through the batched parent query and the whole ledger arrives in one
  # AuditEvent read, leaving a fixed query count however many Blobs are asked
  # for. The OCFL inventory reads stay per-object — each Blob is its own OCFL
  # object, so there is nothing to fold.
  #
  # @return [Hash{String => Array<Hash>}] Blob NOID => its descriptors, newest
  #   first. A Blob holding no bytes maps to an empty array.
  def self.descriptors_for_many(blobs:)
    blobs = Array(blobs).compact
    return {} if blobs.empty?

    events = FileEventLedger.for_blobs(blobs)
    blobs.to_h { |blob| [blob.noid, descriptors(blob: blob, file_events: events.fetch(blob.noid, []))] }
  end

  # file_events, when given, is this Blob's slice of the file audit ledger,
  # already resolved by the caller (see .descriptors_for_many); nil means look
  # it up.
  def initialize(blob, file_events: nil)
    @blob = blob
    @preloaded_file_events = file_events
  end

  # Reverse-chronological descriptors (newest first), one per retained content
  # revision. Empty when the Blob holds no bytes.
  #
  # The 1-based position in file_identifiers IS the contiguous content-revision
  # ordinal (revision 1 = seed): file_identifiers holds only content writes, so
  # it never skips the way the OCFL vN label does (envelope bumps consume vNs).
  # We number in forward order, then reverse to present newest-first.
  def descriptors
    return [] if blob.nil? || blob.file_identifiers.blank?

    seed = blob.file_identifiers.first
    blob.file_identifiers.each_with_index.map do |file_identifier, index|
      descriptor_for(file_identifier, seed, revision: index + 1)
    end.reverse
  end

  # The stored File handle for the content revision identified by its OCFL
  # version label (e.g. 'v4'), or nil if the Blob has no such revision.
  # Resolution goes through file_identifiers (the content revisions only), so
  # an envelope-only version label never resolves — you can only retrieve bytes
  # the listing surfaced.
  def find_file(version_id)
    return nil if blob.nil?

    file_identifier = blob.file_identifiers.find { |fid| version_label(fid) == version_id }
    return nil if file_identifier.nil?

    storage_adapter.find_by(id: file_identifier)
  rescue Valkyrie::StorageAdapter::FileNotFound
    nil
  end

  private

    attr_reader :blob

    def descriptor_for(file_identifier, seed, revision:)
      event = event_for(file_identifier, seed: seed)
      facts = version_facts[file_identifier.to_s] || {}
      {
        revision:          revision,
        version_id:        version_label(file_identifier),
        file_identifier:   file_identifier.to_s,
        created:           facts[:created],
        actor_nuid:        event&.actor_nuid,
        on_behalf_of_nuid: event&.on_behalf_of_nuid,
        digest:            qualified_digest(facts[:digest]),
        size:              facts[:size],
        original_filename: blob.original_filename
      }
    end

    def storage_adapter
      Valkyrie.config.storage_adapter
    end

    # The OCFL version label a revision's identifier names. The adapter owns the
    # id grammar, so ask it rather than re-parse the string here.
    def version_label(file_identifier)
      storage_adapter.version_label_for(file_identifier)
    end

    # created / digest / size per revision, keyed by the revision's own file
    # identifier, from a single inventory read.
    #
    # Each identifier carries both its version and its logical path, and both
    # matter: a replace writes the bytes under the uploaded file's name, so a
    # revision's logical path need not be the current one. Asking the inventory
    # only for the versions holding the *current* path therefore answers nothing
    # for the superseded revisions, which is how a fixity column empties out as
    # soon as a version stops being head.
    def version_facts
      @version_facts ||= storage_adapter.find_version_metadata_for(ids: blob.file_identifiers)
    end

    # Self-describing "<algorithm>:<hexvalue>" fixity as recorded at that
    # version, read from the inventory without re-hashing — same shape as the
    # Blob's denormalized head `digest`.
    def qualified_digest(value)
      value && "#{storage_adapter.digest_algorithm}:#{value}"
    end

    # The file AuditEvent that attributes a revision. A replace_file event
    # stamps the exact version id it produced, so subsequent revisions match by
    # id; the seed revision (the first file_identifier) is the one add_file
    # recorded for this Blob. Either may be absent (a migrated/back-loaded Blob
    # with no controller-sourced event), in which case attribution is null.
    def event_for(file_identifier, seed:)
      replace_events_by_version[file_identifier.to_s] ||
        (file_identifier == seed ? add_file_event : nil)
    end

    def replace_events_by_version
      @replace_events_by_version ||=
        file_events.select { |event| event.action == 'replace_file' }
                   .index_by { |event| event.payload['version_id'] }
    end

    def add_file_event
      @add_file_event ||= file_events.find { |event| event.action == 'add_file' }
    end

    # This Blob's rows from the file audit ledger — preloaded by a batch caller,
    # otherwise resolved here. Empty when the Blob has no resolvable parent Work
    # (orphan), in which case attribution is null.
    def file_events
      @file_events ||= @preloaded_file_events || FileEventLedger.for_blob(blob)
    end
end
