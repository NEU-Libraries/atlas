# frozen_string_literal: true

class TombstoneIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    {
      tombstoned_bsi: resource.tombstoned ? 'true' : 'false',
      tombstoned_at_dti: resource.tombstoned_at,
      tombstoned_by_ssi: resource.tombstoned_by
    }
  end
end
