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
# contributor_ssim rides along here rather than in MODSIndexer, even though no
# Scholar meta tag reads it. It is the SAME filter over the same `names`
# projection that creator_ssim is, only inverted, and the two have to stay
# disjoint: a second file applying its own role rule is how one name ends up in
# both facets or in neither. Contributor names reached Solr under no name at
# all before this -- `Flynn, Stephen E.` was findable only through the
# all_text_timv catch-all -- so a contributor facet was impossible rather than
# merely unconfigured.
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

    # The names one browse axis holds. MODSBrowse decides which axis a name
    # belongs to, so the facet and the display markers cannot disagree about a
    # name -- a marker naming an axis the index does not hold is a link that
    # leads to an empty result set.
    def names_on(axis)
      Array(mods&.names).select { |entry| MODSBrowse.name_axis(entry) == axis }
                        .map(&:name).compact_blank.uniq
    end

    def pub_year
      @pub_year ||= mods&.date_created&.year&.to_s
    end
end
