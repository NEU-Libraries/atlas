# frozen_string_literal: true

# The citation fields Cerberus needs to emit Highwire Press / Google Scholar
# <meta> tags WITHOUT parsing MODS XML on every render -- a hard DPS design
# constraint. Reads the JSON access copy only. See docs/solr-indexing.md.
#
# contributor_ssim rides along here rather than in MODSIndexer because it is
# the SAME filter over the same `names` projection as creator_ssim, only
# inverted, and the two must stay disjoint: a second file applying its own role
# rule is how one name lands in both facets or in neither.
class CitationIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless resource.is_a?(Work)

    fields = {}
    fields[:creator_ssim] = creators if creators.any?
    fields[:contributor_ssim] = contributors if contributors.any?
    fields[:pub_date_ssim] = pub_year if pub_year
    fields
  end

  private

    def mods
      @mods ||= resource.mods
    end

    def creators = @creators ||= names_on(MODSBrowse::CREATOR)

    def contributors = @contributors ||= names_on(MODSBrowse::CONTRIBUTOR)

    # MODSBrowse decides the axis, so the facet and the display markers cannot
    # disagree: a marker naming an axis the index does not hold is a link to an
    # empty result set.
    def names_on(axis)
      Array(mods&.names).select { |entry| MODSBrowse.name_axis(entry) == axis }
                        .map(&:name).compact_blank.uniq
    end

    def pub_year
      created = mods&.date_created
      @pub_year ||= created&.year&.to_s
    end
end
