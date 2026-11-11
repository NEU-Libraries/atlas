# frozen_string_literal: true

# The citation facts of a Work, read from the JSON access copy: who made it,
# when, and what to call it. CitationIndexer indexes them for search and for
# Cerberus's Google Scholar tags, and GET /works/{id}/citation serves them as
# CSL-JSON, so both read one rule. See docs/citation.md.
class Citation
  # Genre terms that name a CSL type outright, checked before the type of
  # resource, which is coarser. Keys are lowercase.
  GENRE_TYPES = {
    'thesis' => 'thesis', 'dissertation' => 'thesis', 'theses & dissertations' => 'thesis',
    'report' => 'report', 'technical report' => 'report', 'technical reports' => 'report',
    'article' => 'article', 'research publications' => 'article',
    'book' => 'book', 'map' => 'map', 'dataset' => 'dataset'
  }.freeze

  # MODS typeOfResource values and the CSL type each reads as.
  RESOURCE_TYPES = {
    'text' => 'document', 'cartographic' => 'map', 'notated music' => 'musical_score',
    'sound recording' => 'song', 'sound recording-musical' => 'song',
    'sound recording-nonmusical' => 'song', 'still image' => 'graphic',
    'moving image' => 'motion_picture', 'software, multimedia' => 'software',
    'mixed material' => 'collection', 'three dimensional object' => 'document'
  }.freeze

  DEFAULT_TYPE = 'document'

  # The date parts a CSL date carries at each precision the record can state.
  DATE_PARTS = { 'year' => 1, 'month' => 2, 'day' => 3 }.freeze

  def initialize(work)
    @work = work
    @mods = work.mods
  end

  # MODSBrowse decides the axis, so the creator facet, the display markers and
  # the citation cannot disagree about who made the Work.
  def creators = names_on(MODSBrowse::CREATOR)
  def contributors = names_on(MODSBrowse::CONTRIBUTOR)

  # The created date: the date search reports as `year`.
  def year
    created = @mods&.date_created
    created&.year&.to_s
  end

  def title = Metadata::MODS.compose_plain_title(@mods&.main_title&.attributes)
  def abstract = @mods&.abstract.presence
  def keywords = Array(@mods&.topical_subjects).compact_blank
  def url = @mods&.permanent_url.presence

  def csl_type
    genre = Array(@mods&.genres).filter_map { |entry| GENRE_TYPES[entry.value.to_s.downcase] }.first
    genre || Array(@mods&.resource_type).filter_map { |entry| RESOURCE_TYPES[entry.value.to_s.downcase] }.first ||
      DEFAULT_TYPE
  end

  # A CSL date to the precision the record states; the record's own words when
  # it gives a date it could not encode; nil when it gives none.
  def issued
    created = @mods&.date_created
    return { 'date-parts' => [date_parts(created)] } if created
    return { 'literal' => @mods.date_created_text } if @mods&.date_created_text.present?

    nil
  end

  private

    def names_on(axis)
      Array(@mods&.names).select { |entry| MODSBrowse.name_axis(entry) == axis }
                         .map(&:name).compact_blank.uniq
    end

    def date_parts(date)
      [date.year, date.month, date.day].first(DATE_PARTS.fetch(@mods.date_created_precision.to_s, 3))
    end
end
