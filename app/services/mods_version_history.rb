# frozen_string_literal: true

# Assembles a resource's MODS version history from the OCFL storage layer.
#
# Read-only and entirely derived — it mints no storage and mutates nothing.
# OCFL is the source of truth for the version labels and timestamps
# (find_version_metadata); the AuditEvent ledger supplies actor attribution,
# correlated to each version by timestamp proximity. Either side may be
# absent (no MODS blob yet, or no correlatable event), in which case the
# history is empty or actor_nuid is null respectively.
#
# Only XML is version-recoverable: every descriptive-metadata edit appends a
# new OCFL version of descMetadata.xml, whereas the JSON access copy
# (Metadata::MODS) is overwritten in place (see Modsable#mods_json=). So this
# object lists every version and fetches any version's raw XML, but never
# JSON — a per-version JSON would have to be re-derived from the historical
# XML, which is intentionally out of scope here.
class MODSVersionHistory
  # The metadata-edit AuditEvent fires immediately after the OCFL upload,
  # within the same request (WorksController#binary_update: mods_xml= then
  # audit!), so occurred_at trails the version `created` by well under a
  # second. Allow a generous window to absorb clock granularity / skew, and
  # pick the closest event inside it.
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

  # Reverse-chronological descriptors (newest first), mirroring the
  # AuditEvent field names so a consumer can render the version list with the
  # same helpers it uses for /history.
  #
  # We report *content-distinct* MODS states, not raw OCFL revisions. The
  # descriptive-metadata Blob shares its NOID-keyed OCFL object with its own
  # preservation envelope (properties.json / permissions.json), and OCFL state
  # is cumulative — so an envelope re-write (e.g. the backfill rake task) cuts
  # a new version that still carries descMetadata.xml at its prior, unchanged
  # digest. Surfacing those byte-identical revisions as separate "versions"
  # gives the diff UI empty no-ops. We coalesce consecutive identical digests,
  # keeping the *earliest* of each run — the moment the content became that
  # state, which is also when its correlated edit event fired. Only
  # consecutive runs collapse, so a genuine A→B→A still yields three versions.
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

  # Raw historical descMetadata.xml for a given OCFL version label (e.g.
  # 'v2'), or nil if the resource has no MODS or the version is unknown. We
  # locate the version through find_versions rather than reconstructing the
  # per-version id by hand, so id construction stays the adapter's concern.
  def fetch_xml(version_id)
    return nil if blob.nil?

    file = storage_adapter.find_versions(id: blob.latest_revision).find do |f|
      f.version_id.to_s.split('/')[-2] == version_id
    end
    file&.read
  end

  private

    attr_reader :resource

    # Collapse runs of consecutive byte-identical revisions (same content
    # digest) into one, keeping the earliest of each run. Input is newest-first
    # (as find_version_metadata returns); we walk oldest→newest so "earliest of
    # run" is the first seen, then restore newest-first ordering. Entries
    # without a digest (defensive) are never coalesced. Pure metadata — no
    # content fetch.
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

    # Closest metadata/mods AuditEvent to a version's creation time, within
    # the correlation window; nil if none is close enough. Matching is
    # timestamp-proximity (the OCFL `user` field is the app user_agent, not
    # the editing NUID), so attribution is best-effort: the seed version a
    # Work is born with has no edit event and resolves to null.
    def correlated_event(created_iso)
      return nil if created_iso.blank?

      created   = Time.iso8601(created_iso)
      candidate = mods_events.min_by { |e| (e.occurred_at - created).abs }
      return nil if candidate.nil?

      (candidate.occurred_at - created).abs <= CORRELATION_WINDOW ? candidate : nil
    end

    # The writer stamps resource_id with the Valkyrie UUID (resource.id), not
    # the NOID; we have the live resource here, so match on the UUID directly.
    #
    # Every change_type:'metadata' event is a MODS-touching edit: a
    # full-document replace via the binary `mods_xml=` path (binary_update),
    # tagged payload { source: 'mods' }. Descriptive fields are written only
    # through that full-document upload — the caller assembles the MODS it
    # sends; there are no flat per-field setters on the metadata PATCH.
    def mods_events
      @mods_events ||=
        AuditEvent.for_resource(resource.id.to_s)
                  .where(change_type: 'metadata')
                  .to_a
    end

    # The kind of edit that produced a version — currently always a
    # full-document MODS replace ('mods'). Derived from the correlated event's
    # payload shape; nil when there's no correlated event (e.g. the template
    # seed).
    def source_for(event)
      payload = event&.payload
      return nil if payload.nil?

      payload['source']
    end
end
