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
# The field names are v1's, and for ASCII text so is the normalisation, so a
# sort that worked in v1 orders the same way here. Text outside ASCII folds to
# its base letters (see SORT_NOISE) rather than being dropped, so an accented
# title files under its own initial and a title in a non-Latin script still gets
# a key at all. Sources are the JSON access copy (resource.mods) and — for a
# resource that carries no MODS — its display name, so no MODS XML is parsed on
# either the write path or the read path.
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

  # Sorting ignores punctuation and case, but never a letter. A letter outside
  # a-z folds to the base letter underneath it where there is one and is
  # otherwise kept as itself, so nothing a curator can type leaves a resource
  # with no sort key at all. A kept character sorts by codepoint, which groups a
  # script together after the Latin range.
  SORT_NOISE = /[^\p{L}\p{N} ]/

  # A combining mark left over from decomposition: dropping it is what folds an
  # "e" carrying an acute accent down to a plain "e". Unicode's own case folding
  # covers a letter that has no decomposition but does have an equivalent (the
  # eszett to "ss", a final sigma to a medial one), and the transliteration
  # table covers the rest (a slashed o to "o", a thorn to "th").
  COMBINING_MARK = /\p{M}/

  # What the transliteration table answers for a character it holds no entry
  # for, a CJK ideograph or a Greek letter among them. Such a character is kept
  # as itself, never replaced by this.
  UNFOLDABLE = '?'

  # An article a record carries in the title itself rather than in nonSort.
  LEADING_ARTICLE = /\A(?:a|an|the) /

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

      # Enhanced-text markup comes out before normalising: SORT_NOISE drops "<",
      # ">" and "/" as ordinary punctuation, which welds the word "sub" and the
      # subscript digits into the key ("bisub000002subsr..."). The sort field is
      # never displayed, so plain text is unambiguously the right form here.
      EnhancedText.strip(NEU::MODS.compose_title(parts.except(:non_sort)))
    end

    # The name a resource that holds no MODS is titled by — a Person, whose
    # authoritative display_name PersonIndexer already projects into title_tsim
    # for display and keyword search. Sorting reads the same source, so the two
    # agree; a Person with no sort title at all would sort as missing.
    def display_name
      resource.try(:display_name)
    end

    def normalize(value)
      fold(value)
        .gsub(SORT_NOISE, '')
        .sub(LEADING_ARTICLE, '')
        .gsub(NUMBER_RUN, "#{NUMBER_PAD}\\1")
        .gsub(PADDED_RUN, '\1')
        .squish
    end

    # Text case-folded and reduced to its base letters. Case folding, then
    # decomposition so that a diacritic becomes a separate mark to drop, then
    # transliteration for the letters those two leave whole. Together they are
    # the folding Solr's ICUFoldingFilter already applies to title_tsim, so
    # sorting and matching agree on what a letter is.
    def fold(value)
      value.to_s.downcase(:fold)
           .unicode_normalize(:nfkd)
           .gsub(COMBINING_MARK, '')
           .each_char.map { |char| fold_char(char) }.join
    end

    def fold_char(char)
      return char if char.ascii_only?

      folded = ActiveSupport::Inflector.transliterate(char, UNFOLDABLE)
      folded.include?(UNFOLDABLE) ? char : folded
    end

    # The primary creator: the first name in a creator role, or — when no name
    # declares one — the first name of any role, so a resource whose only names
    # are contributors still sorts under a name instead of to the end of the
    # list. A name keeps its punctuation, because "Lee, Wen-Han" is already in
    # filing order; it is case- and diacritic-folded like a title, so a name
    # opening on an accented letter files under that letter rather than after Z.
    def sort_creator
      @sort_creator ||= fold(creator_names.first || names.first).squish
    end

    def names
      @names ||= Array(mods&.names).map(&:name).compact_blank
    end

    def creator_names
      @creator_names ||= Array(mods&.names)
                         .select { |name| Array(name.roles).any? { |role| MarcRelators.creator?(role) } }
                         .map(&:name).compact_blank
    end

    # MODS lets a record nominate its own principal date with keyDate="yes", and
    # DATE_FIELDS overruled it with a fixed preference for dateCreated. A
    # flagged date wins now; the order is kept for the records that set no flag,
    # which is most of them, and for the ones that flag the date it would have
    # picked anyway.
    #
    # A ranged date sorts on its start. That is what it did before by accident,
    # because the gem returned the first node; it is deliberate now, so the
    # behaviour survives the gem reading the points by attribute.
    def sort_date
      @sort_date ||= key_date || DATE_FIELDS.filter_map { |field| mods&.public_send(field) }.first
    end

    def key_date
      DATE_FIELDS.filter_map do |field|
        mods.public_send(field) if mods&.public_send(:"#{field}_key_date")
      end.first
    end
end
