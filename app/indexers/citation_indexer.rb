# frozen_string_literal: true

# Projects a Work's citation-relevant MODS fields onto the Work's own Solr doc
# so Cerberus can emit Highwire Press / Google Scholar `<meta>` tags
# (citation_author, keywords, citation_publication_date) in the Work show
# `<head>` — WITHOUT parsing MODS XML on every render (a hard DPS design
# constraint). The Work Solr doc already carries title / abstract / genre /
# access; this indexer adds the three pieces Scholar needs that were missing:
# structured creators, keywords, and a publication year.
#
# All three sources live in the JSON access copy (Metadata::MODS, reachable on
# any Modsable resource via resource.mods), so this reads them straight off the
# resource — no Nokogiri, same read-path discipline as GenreIndexer:
#
#   creator_ssim  <- creator-role names, display form (one citation_author each)
#   pub_date_ssim <- publication year (citation_publication_date); single value,
#                    reusing Cerberus's existing "Publication Year" facet field.
#
# The keywords meta reads subject_ssim, which MODSIndexer writes for every
# Modsable resource rather than for Works alone. This indexer used to write the
# same values as keyword_ssim; that name said "keyword" while carrying
# topical_subjects, which are a wider set than the gem's #keywords, and having
# two indexers write one concept meant either could drift.
#
# The field names are the contract the Cerberus consumer reads. Each projects
# only when its source is present; empty hash for anything that isn't a Work and
# for a Work missing the data — the fields appear once the data is set and the
# Work is next saved / reindexed (same lifecycle as genre_ssim).
class CitationIndexer
  # MODS roleTerm display value marking an author/creator (corporate and
  # personal creators both carry this in the corpus). Contributors and other
  # roles are excluded — Scholar's citation_author is authors only, matching
  # v1's creator-only gate.
  CREATOR_ROLE = 'creator'

  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless resource.is_a?(Work)

    fields = {}
    fields[:creator_ssim] = creators if creators.any?
    fields[:pub_date_ssim] = pub_year if pub_year
    fields
  end

  private

    def mods
      @mods ||= resource.mods
    end

    def creators
      @creators ||= Array(mods&.names)
                    .select { |n| n.role.to_s.casecmp?(CREATOR_ROLE) }
                    .map(&:name).compact_blank.uniq
    end

    def pub_year
      @pub_year ||= mods&.date_created&.year&.to_s
    end
end
