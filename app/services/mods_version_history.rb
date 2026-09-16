# frozen_string_literal: true

# A resource's MODS version history, assembled from OCFL plus the AuditEvent
# ledger. Read-only and entirely derived. See docs/mods.md.
#
# Only XML is version-recoverable: every edit appends a new OCFL version of
# descMetadata.xml, whereas the JSON access copy is overwritten in place. So
# this never serves a per-version JSON -- it would have to be re-derived from
# the historical XML, which is out of scope.
class MODSVersionHistory
  # The edit event fires immediately after the OCFL upload in the same request,
  # so occurred_at trails `created` by well under a second. Generous on purpose
  # to absorb clock granularity and skew.
  CORRELATION_WINDOW = 5.seconds

  def self.descriptors(resource:)
    new(resource).descriptors
  end

  def self.fetch_xml(resource:, version_id:)
    new(resource).fetch_xml(version_id)
  end

  def initialize(resource)
    @resource = resource
  end

  # Newest first, mirroring the AuditEvent field names so a consumer renders
  # this with the same helpers it uses for /history.
  #
  # Reports CONTENT-DISTINCT states, not raw OCFL revisions: the blob shares
  # its OCFL object with its preservation envelope, so an envelope re-write
  # cuts a version carrying descMetadata.xml at its prior digest.
  def descriptors
    return [] if blob.nil?

    metadata = storage_adapter.find_version_metadata(id: blob.latest_revision)
    collapse_consecutive_identical(metadata).map do |version|
      event = correlated_event(version[:created])
      {
        version_id:        version[:version],
        created:           version[:created],
        actor_nuid:        event&.actor_nuid,
        on_behalf_of_nuid: event&.on_behalf_of_nuid,
        source:            source_for(event),
        note:              event&.note
      }
    end
  end

  # Located through find_versions rather than by reconstructing the per-version
  # id, so id construction stays the storage adapter's concern.
  def fetch_xml(version_id)
    return nil if blob.nil?

    file = storage_adapter.find_versions(id: blob.latest_revision).find do |f|
      storage_adapter.version_label_for(f.version_id) == version_id
    end
    file&.read
  end

  private

    attr_reader :resource

    # Input is newest-first, so this walks oldest->newest to make "earliest of
    # run" the first seen, then restores the order. Only CONSECUTIVE runs
    # collapse, so a genuine A->B->A still yields three versions. Entries with
    # no digest are never coalesced.
    def collapse_consecutive_identical(versions)
      kept = []
      versions.reverse_each do |version|
        prev = kept.last
        next if prev && version[:digest] && prev[:digest] == version[:digest]

        kept << version
      end
      kept.reverse
    end

    def blob
      return nil unless resource.respond_to?(:mods_blob)

      @blob ||= resource.mods_blob
    end

    def storage_adapter
      Valkyrie.config.storage_adapter
    end

    # Timestamp proximity, because the OCFL `user` field holds the app's user
    # agent rather than the editing NUID -- there is no id to join on. So
    # attribution is best-effort, and the seed version resolves to null.
    def correlated_event(created_iso)
      return nil if created_iso.blank?

      created   = Time.iso8601(created_iso)
      candidate = mods_events.min_by { |e| (e.occurred_at - created).abs }
      return nil if candidate.nil?

      (candidate.occurred_at - created).abs <= CORRELATION_WINDOW ? candidate : nil
    end

    # The writer stamps resource_id with the Valkyrie UUID, not the NOID, and
    # the live resource is in hand here. Every change_type:'metadata' event is
    # a MODS edit: descriptive fields are written only through the
    # full-document mods_xml= upload.
    def mods_events
      @mods_events ||=
        AuditEvent.for_resource(resource.id.to_s)
                  .where(change_type: 'metadata')
                  .to_a
    end

    # nil when there is no correlated event, such as the template seed.
    def source_for(event)
      payload = event&.payload
      return nil if payload.nil?

      payload['source']
    end
end
