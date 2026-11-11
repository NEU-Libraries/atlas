# frozen_string_literal: true

# The citation fields Cerberus needs to emit Highwire Press / Google Scholar
# <meta> tags WITHOUT parsing MODS XML on every render -- a hard DPS design
# constraint. Reads the JSON access copy only. See docs/solr-indexing.md.
#
# The rule for who made the Work and when lives in Citation, which
# GET /works/{id}/citation also serves, so the facets and the citation cannot
# disagree. creator_ssim and contributor_ssim are the same filter over the same
# `names` projection, only inverted, and must stay disjoint.
class CitationIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless resource.is_a?(Work)

    citation = Citation.new(resource)
    fields = {}
    fields[:creator_ssim] = citation.creators if citation.creators.any?
    fields[:contributor_ssim] = citation.contributors if citation.contributors.any?
    fields[:pub_date_ssim] = citation.year if citation.year
    fields
  end
end
