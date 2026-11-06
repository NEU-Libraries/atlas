# frozen_string_literal: true

# Projects when a Work's MODS XML last changed, read from the OCFL version
# history rather than stored, so it survives a reindex, a reproject and a
# rebuild from disk. See docs/solr-indexing.md.
#
#   mods_updated_at_dtsi <- the newest content-distinct MODS version's time
class MODSEditDateIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless resource.is_a?(Work)

    changed = MODSVersionHistory.last_changed_at(resource: resource)
    changed ? { mods_updated_at_dtsi: changed.iso8601 } : {}
  end
end
