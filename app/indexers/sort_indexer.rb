# frozen_string_literal: true

# The three single-valued fields a result list sorts on -- title_ssi,
# creator_ssi, date_ssi -- none of them ever displayed. See
# docs/solr-indexing.md.
#
# Solr sorts on a single-valued field ONLY, and every descriptive field indexed
# for display is multi-valued, so a Sort control had nothing to sort on. The
# failure is SILENT: Solr accepts the sort and returns index order.
#
# date_ssi and created_at_dtsi are deliberately different sorts: one is when
# the repository made the record, the other when the thing was made.
class SortIndexer
  # Numbers sort as text in a string field, so each run of digits is left-padded
  # to six characters ("Chapter 2" before "Chapter 10"). Applied as v1 applied
  # it: prepend five zeros, then trim any run of 6+ digits back down.
  NUMBER_RUN = /(\d+)/
  PADDED_RUN = /0*([0-9]{6,})/
  NUMBER_PAD = '00000'

  # Ignores punctuation and case but NEVER a letter, so nothing a curator can
  # type leaves a resource with no sort key at all.
  SORT_NOISE = /[^\p{L}\p{N} ]/

  # Dropping this is what folds an accented "e" down to a plain one.
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

    # MODS records an article as nonSort precisely to say "do not sort on
    # this"; LEADING_ARTICLE catches records that put it in the title instead.
    def composed_title
      main_title = mods&.main_title
      parts = main_title&.attributes&.symbolize_keys
      return nil if parts.blank?

      # Stripped BEFORE normalising: SORT_NOISE drops "<", ">" and "/" as
      # ordinary punctuation, which welds "sub" and the subscript digits into
      # the key ("bisub000002subsr...").
      EnhancedText.strip(NEU::MODS.compose_title(parts.except(:non_sort)))
    end

    # PersonIndexer projects this same display_name into title_tsim, so
    # sorting and display agree.
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

    # The same folding Solr's ICUFoldingFilter applies to title_tsim, so
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

    # Falls back to the first name of ANY role, so a resource whose only names
    # are contributors still sorts under a name. Punctuation is kept: "Lee,
    # Wen-Han" is already in filing order.
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

    # A keyDate="yes" date wins; DATE_FIELDS orders the rest. A ranged date
    # sorts on its START, deliberately.
    def sort_date
      @sort_date ||= key_date || DATE_FIELDS.filter_map { |field| mods&.public_send(field) }.first
    end

    def key_date
      DATE_FIELDS.filter_map do |field|
        mods.public_send(field) if mods&.public_send(:"#{field}_key_date")
      end.first
    end
end
