# frozen_string_literal: true

# Stored (`_dtsi`), not just indexed: the admin tombstone registry filters,
# sorts and displays by the withdrawal date, and a field Solr does not store
# never appears in the document it reads back. See docs/solr-indexing.md.
class TombstoneIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    {
      tombstoned_bsi:     resource.tombstoned ? 'true' : 'false',
      tombstoned_at_dtsi: resource.tombstoned_at,
      tombstoned_by_ssi:  resource.tombstoned_by
    }
  end
end
