# frozen_string_literal: true

# Projects a Collection's `featured` flag onto its Solr doc as featured_bsi, so
# Cerberus can badge genre-showcase Collections ("Featured") in a community's
# Blacklight browse. Boolean-as-string to match TombstoneIndexer's bsi shape.
#
# Collection-only: the showcase concept lives on Collections (the real
# containers the publish conduit links Works into). Empty hash for everything
# else.
class FeaturedIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless resource.is_a?(Collection)

    { featured_bsi: resource.featured ? 'true' : 'false' }
  end
end
