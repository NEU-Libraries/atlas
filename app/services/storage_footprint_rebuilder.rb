# frozen_string_literal: true

# Recomputes the storage_footprints ledger from disk: measures every object in
# every root and drops rows for objects no root holds. The ledger is derived,
# so this is its recovery path when a write could not record its bytes. A full
# walk of the storage, so an operator task, never a request. See
# docs/binaries.md.
#
# Only the owners of rows it corrects are re-indexed, so a rebuild that finds
# no drift costs no Solr writes.
class StorageFootprintRebuilder < ApplicationService
  def initialize(adapter: Valkyrie.config.storage_adapter)
    @adapter = adapter
  end

  def call
    recorded  = StorageFootprint.pluck(:object_key, :bytes).to_h
    measured  = measure_all
    corrected = measured.reject { |key, bytes| recorded[key] == bytes }
    stale     = recorded.keys - measured.keys

    corrected.each do |key, bytes|
      StorageFootprint.set!(key: key, bytes: bytes)
      StorageFootprintRecorder.note(key)
    end
    stale.each { |key| StorageFootprintRecorder.forget!(key: key) }

    { objects: measured.size, bytes: measured.values.sum, corrected: corrected.size, removed: stale.size }
  end

  private

    def measure_all
      @adapter.storage_roots.keys
              .flat_map { |name| @adapter.object_keys(root_name: name) }
              .index_with { |key| @adapter.measure_object(key: key) }
    end
end
