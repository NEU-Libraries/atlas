# frozen_string_literal: true

# Common English diminutives of given names, so a search for "Tim" finds a
# record naming Timothy and the reverse. The table is vendored data; see
# docs/solr-indexing.md#namevariantindexer for the rules and their known
# false positives.
module NameVariants
  SOURCES = %w[male_diminutives.csv female_diminutives.csv].map do |file|
    Rails.root.join('vendor/diminutives.db', file)
  end.freeze

  # The dates an LC heading appends: "Stone, Alyssa, 1990-". Stripped before
  # the split, or the comma form would read "1990-" as part of the given name.
  TRAILING_DATES = /(?:,[^,]*\d[^,]*)+\z/

  module_function

  def fold(name)
    ActiveSupport::Inflector.transliterate(name.to_s).downcase
  end

  # A name can sit in more than one row: "Tim" is under Timon and Timothy.
  # Keyed by folded form, so "Concepcion" finds "Concepción".
  ROWS_BY_NAME = SOURCES.flat_map { |path| File.readlines(path, chomp: true) }
                        .map { |line| line.split(',').compact_blank.freeze }
                        .flat_map { |row| row.map { |name| [fold(name), row] } }
                        .group_by(&:first)
                        .transform_values { |pairs| pairs.map(&:last) }
                        .freeze

  # Every other name sharing a row with this one.
  def for_given(given)
    key = fold(given)
    ROWS_BY_NAME.fetch(key, []).flatten.uniq.reject { |name| fold(name) == key }
  end

  # The name with its given name swapped for each variant, in direct order,
  # because direct order is how a reader types a name into a search box.
  def full_names(name)
    given, family = split(name)
    return [] if given.blank? || family.blank?

    for_given(given).map { |variant| "#{variant} #{family}" }
  end

  # [given, family]. The comma form is how neu-mods composes a personal name;
  # direct order is how a photo desk writes one as a keyword. A middle name or
  # initial is dropped, as a reader searching "Tim Smith" does.
  def split(name)
    text = name.to_s.sub(TRAILING_DATES, '').strip
    if text.include?(',')
      family, given = text.split(',', 2).map(&:strip)
      [given.split.first, family.presence]
    else
      words = text.split
      [words.first, words.size > 1 ? words.last : nil]
    end
  end

  # A topic is free text, so only a short run of capitalized words is read as
  # a possible name. The table still decides: "Northeastern Alumni" passes
  # here and expands to nothing.
  def name_shaped?(text)
    words = text.to_s.sub(TRAILING_DATES, '').split
    words.size.between?(2, 3) && words.all? { |word| word.match?(/\A\p{Lu}/) }
  end
end
