# frozen_string_literal: true

# A Blob's binary version history, assembled from OCFL plus the file audit
# ledger. Read-only and entirely derived. See docs/binaries.md.
#
# The Blob's ordered `file_identifiers` IS the authoritative revision list --
# it holds only content writes -- so this lists straight off that array with
# NO digest coalescing, unlike MODSVersionHistory. An envelope bump never
# appears, and a re-upload of identical bytes is still its own revision.
#
# Attribution matches the version id the replace event recorded EXACTLY, so
# unlike the MODS correlation there is no window to tune.
class BinaryVersionHistory
  def self.descriptors(blob:, file_events: nil)
    new(blob, file_events: file_events).descriptors
  end

  def self.find_file(blob:, version_id:)
    new(blob).find_file(version_id)
  end

  # Attribution is what makes this worth batching: correlating one Blob walks
  # Blob -> FileSet -> Work and reads that Work's ledger. The inventory reads
  # stay per-object -- each Blob is its own OCFL object, nothing to fold.
  def self.descriptors_for_many(blobs:)
    blobs = Array(blobs).compact
    return {} if blobs.empty?

    events = FileEventLedger.for_blobs(blobs)
    blobs.to_h { |blob| [blob.noid, descriptors(blob: blob, file_events: events.fetch(blob.noid, []))] }
  end

  # file_events nil means look the ledger up; a batch caller preloads it.
  def initialize(blob, file_events: nil)
    @blob = blob
    @preloaded_file_events = file_events
  end

  # The 1-based position in file_identifiers IS the contiguous revision
  # ordinal: it never skips the way the OCFL vN label does, because envelope
  # bumps consume vNs. Numbered forward, then reversed to newest-first.
  def descriptors
    return [] if blob.nil? || blob.file_identifiers.blank?

    seed = blob.file_identifiers.first
    blob.file_identifiers.each_with_index.map do |file_identifier, index|
      descriptor_for(file_identifier, seed, revision: index + 1)
    end.reverse
  end

  # Resolves through file_identifiers, so an envelope-only version label never
  # resolves: you can only retrieve bytes the listing surfaced.
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

    # The adapter owns the id grammar, so ask it rather than re-parse.
    def version_label(file_identifier)
      storage_adapter.version_label_for(file_identifier)
    end

    # Keyed on the FULL identifier, version and logical path both: a replace
    # writes bytes under the uploaded file's name, so a revision's path need
    # not be the current one. Asking only for versions holding the current
    # path is how a fixity column empties out once a version stops being head.
    def version_facts
      @version_facts ||= storage_adapter.find_version_metadata_for(ids: blob.file_identifiers)
    end

    # Read from the inventory WITHOUT re-hashing; same shape as the Blob's
    # denormalized head digest.
    def qualified_digest(value)
      value && "#{storage_adapter.digest_algorithm}:#{value}"
    end

    # A replace_file event stamps the EXACT version id it produced, so
    # revisions match by id; the seed matches add_file. Either may be absent
    # on a migrated Blob, in which case attribution is null.
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

    # Empty for an orphan Blob with no resolvable parent Work.
    def file_events
      @file_events ||= @preloaded_file_events || FileEventLedger.for_blob(blob)
    end
end
