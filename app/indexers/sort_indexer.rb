# frozen_string_literal: true

# Projects the three single-valued, sortable fields a discovery result list
# sorts on:
#
#   title_ssi   <- the composed title, normalised for sorting
#   creator_ssi <- the primary creator's name
#   date_ssi    <- the MODS origin date
#
# Solr sorts on a single-valued field only, and every descriptive field Atlas
# indexes for display is multi-valued (title_tsim, creator_ssim) or, in the case
# of an origin date, not indexed at all. A Sort control offering title, creator
# or date therefore had nothing to sort on: Solr accepts the sort, finds the
# field missing on every document, and returns index order, so the failure is
# silent. These three fields exist to be sorted on and are never displayed.
#
# date_ssi and Valkyrie's created_at_dtsi are deliberately different sorts, and
# the distinction is the valuable part: created_at is when the repository made
# the record, date_ssi is when the thing itself was made. For an archival scan
# the second is the only date a reader cares about.
#
# The field names and the normalisation are v1's, so a sort that worked in v1
# orders the same way here. Sources are the JSON access copy (resource.mods) and
# — for a resource that carries no MODS — its display name, so no MODS XML is
# parsed on either the write path or the read path.
#
# title_ssi is the sort form of whatever title_tsim displays, for every resource
# type. Holding to that for a Person is why the title source falls back to a
# display name: a Person's title IS their name, a Person carries no MODS, and a
# Person reaches ordinary catalog results — so an A-Z list has to order one by
# their name.
class SortIndexer
  # Numbers sort as text in a string field, so each run of digits is left-padded
  # to six characters ("Chapter 2" before "Chapter 10"). Applied as v1 applied
  # it: prepend five zeros, then trim any run of 6+ digits back down.
  NUMBER_RUN = /(\d+)/
  PADDED_RUN = /0*([0-9]{6,})/
  NUMBER_PAD = '00000'

  # Sorting ignores punctuation and case.
  SORT_NOISE = /[^0-9a-z ]/

  # An article a record carries in the title itself rather than in nonSort.
  LEADING_ARTICLE = /\A(?:a|an|the) /

  # The MODS roleTerm marking an author/creator, as CitationIndexer reads it.
  CREATOR_ROLE = 'creator'

  # v1's precedence for "the date this thing was made": the date of creation,
  # then the copyright date, then the date of issue. The first one present wins,
  # so a resource carrying only a copyright date still sorts chronologically.
  DATE_FIELDS = %i[date_created copyright_date date_issued].freeze

  # Sortable dates are written as a full UTC instant, one format for every
  # document, because a string field sorts by bytes: ISO-8601 sorts
  # chronologically only while every value has the same shape.
  DATE_FORMAT = '%Y-%m-%dT%H:%M:%SZ'

  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    fields = {}
    fields[:title_ssi] = sort_title if sort_title.present?
    fields[:creator_ssi] = sort_creator if sort_creator.present?
    fields[:date_ssi] = sort_date.utc.strftime(DATE_FORMAT) if sort_date
    fields
  end

  private

    # Memoized including a nil answer: every resource is Modsable, so a lookup
    # costs a query even for the file-level resources that never hold MODS, and
    # this runs on every save.
    def mods
      return @mods if defined?(@mods)

      @mods = resource.try(:mods)
    end

    def sort_title
      @sort_title ||= normalize(composed_title.presence || display_name)
    end

    # The composed title without its nonSort prefix. MODS records the article as
    # nonSort precisely to say "do not sort on this", so the sort key drops it;
    # LEADING_ARTICLE then catches the records that put the article in the title
    # instead. Composition reuses the shared helper the display title uses, so
    # the two orders agree on subtitles and part numbers.
    def composed_title
      parts = mods&.main_title&.attributes&.symbolize_keys
      return nil if parts.blank?

      NEU::MODS.compose_title(parts.except(:non_sort))
    end

    # The name a resource that holds no MODS is titled by — a Person, whose
    # authoritative display_name PersonIndexer already projects into title_tsim
    # for display and keyword search. Sorting reads the same source, so the two
    # agree; a Person with no sort title at all would sort as missing.
    def display_name
      resource.try(:display_name)
    end

    def normalize(value)
      value.to_s.downcase
           .gsub(SORT_NOISE, '')
           .sub(LEADING_ARTICLE, '')
           .gsub(NUMBER_RUN, "#{NUMBER_PAD}\\1")
           .gsub(PADDED_RUN, '\1')
           .squish
    end

    # The primary creator: the first name in a creator role, or — when no name
    # declares one — the first name of any role, so a resource whose only names
    # are contributors still sorts under a name instead of to the end of the
    # list. Names sort case-folded, like titles.
    def sort_creator
      @sort_creator ||= (creator_names.first || names.first).to_s.downcase.squish
    end

    def names
      @names ||= Array(mods&.names).map(&:name).compact_blank
    end

    def creator_names
      @creator_names ||= Array(mods&.names)
                         .select { |name| name.role.to_s.casecmp?(CREATOR_ROLE) }
                         .map(&:name).compact_blank
    end

    def sort_date
      @sort_date ||= DATE_FIELDS.filter_map { |field| mods&.public_send(field) }.first
    end
end
