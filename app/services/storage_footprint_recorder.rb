# frozen_string_literal: true

# The storage adapter's footprint_recorder. Keeps the storage_footprints ledger
# and re-indexes the Work or container that owns each object it touches, so
# that resource's storage_bytes_ls stays current. See docs/binaries.md.
#
# Inside a batch, owners are collected and re-indexed once when the outermost
# batch ends. Controller actions and service calls each run in one, because a
# single ingest writes six or more versions under one Work. Outside a batch the
# owner is re-indexed at once.
class StorageFootprintRecorder
  STATE_KEY = :storage_footprint_batch

  class << self
    def add!(key:, bytes:)
      StorageFootprint.add!(key: key, bytes: bytes)
      note(key)
    end

    # The owner is resolved before the row goes: a purge deletes storage
    # before the resource, and the resource is how the owner is found.
    def forget!(key:)
      owner = owner_of(key)
      StorageFootprint.forget!(key: key)
      owner ? note_owner(owner) : nil
    end

    # Owners are resolved when the batch ends, not when a byte is written,
    # because a new Blob's bytes land before the edge that links it.
    def note(key)
      return reindex([key]) if pending.nil?

      pending[:keys] << key.to_s
    end

    def batch
      return yield unless pending.nil?

      self.pending = { keys: Set.new, owners: {} }
      begin
        yield
      ensure
        flush(pending)
        self.pending = nil
      end
    end

    # The Work, Collection or Community whose storage_bytes_ls counts this
    # object, or nil for a key with no resource or no such ancestor.
    def owner_of(key)
      resource = Atlas.query.custom_queries.find_many_by_alternate_identifiers(alternate_identifiers: [key.to_s]).first
      climb(resource)
    end

    private

      def pending
        ActiveSupport::IsolatedExecutionState[STATE_KEY]
      end

      def pending=(value)
        ActiveSupport::IsolatedExecutionState[STATE_KEY] = value
      end

      def note_owner(owner)
        return index(owner) if pending.nil?

        pending[:owners][owner.id.to_s] = owner
      end

      def reindex(keys)
        keys.filter_map { |key| owner_of(key) }.uniq(&:id).each { |owner| index(owner) }
      end

      # A failure here must not fail the write that raised it: the bytes are on
      # disk and in the ledger, and a reindex corrects the figure.
      def flush(state)
        owners = state[:keys].filter_map { |key| owner_of(key) }
        (owners + state[:owners].values).uniq(&:id).each { |owner| index(owner) }
      rescue StandardError => e
        Rails.logger.error("storage footprint reindex failed: #{e.class}: #{e.message}")
      end

      # Re-read, so the document reflects the resource as the write left it.
      # An in-progress Work waits for POST /works/:id/complete, which indexes
      # it, so an N-page deposit does not re-index its Work N times.
      def index(owner)
        fresh = Atlas.query.find_by(id: owner.id)
        return if fresh.is_a?(Work) && fresh.in_progress

        Atlas.index_adapter.persister.save(resource: fresh)
      rescue Valkyrie::Persistence::ObjectNotFoundError
        nil
      end

      def climb(resource)
        return nil if resource.nil?
        return resource if StorageFootprintQuery::OWNER_TYPES.include?(resource.class.name)

        parent_id = resource.respond_to?(:a_member_of) ? resource.a_member_of : nil
        parent = parent_id ? Atlas.query.find_by(id: parent_id) : Atlas.query.find_parents(resource: resource).first
        climb(parent)
      rescue Valkyrie::Persistence::ObjectNotFoundError
        nil
      end
  end
end
