# frozen_string_literal: true

# A resource's MODS version history. See MetadataVersionHistory.
class MODSVersionHistory < MetadataVersionHistory
  private

    def blob
      return nil unless resource.respond_to?(:mods_blob)

      @blob ||= resource.mods_blob
    end

    # Descriptive fields are written only through the full-document mods_xml=
    # upload, so every metadata event is a MODS edit except an additional
    # record's, which shares the change type and names itself in `source`.
    def edit_events(events)
      events.where("payload->>'source' IS NULL OR payload->>'source' NOT IN (?)",
                   MetadataRecords::SOURCES)
    end
end
