# frozen_string_literal: true

# A Work's Darwin Core version history. See MetadataVersionHistory.
class DarwinCoreVersionHistory < MetadataVersionHistory
  private

    def blob
      return nil unless resource.respond_to?(:darwin_core_blob)

      @blob ||= resource.darwin_core_blob
    end

    # Only an `update` writes the file. A withdrawal touches the FileSet's
    # envelope instead, so it must not be matched to a version of the Blob.
    def edit_events(events)
      events.where(action: 'update').where("payload->>'source' = ?", MetadataRecords::DarwinCore::SOURCE)
    end
end
