# frozen_string_literal: true

module WorkDecorator
  include DecoratorHelper
  include MODSDecoration
  include ThumbnailProjection

  # One row per displayed field, in display order. This is the ONE place a row
  # is added: the views render #mods_rows rather than listing fields, so a field
  # can no longer be projected and stored and then silently not render because
  # someone forgot a line in two byte-identical templates.
  #
  # :label is what a reader sees. :render names a method for a field whose
  # markup is more than a label and a value -- a grouped label, a composed
  # title, a date formatted to its declared precision. :titleize and :link are
  # the two per-value transforms plain rows need.
  #
  # Labels live here and not in neu-mods on purpose. A label is display
  # vocabulary, and Cerberus's edit form words the same field differently; the
  # gem owns what a field IS, this owns what it looks like.
  DISPLAY = [
    { field: :main_title, render: :title },
    { field: :names, render: :names },
    { field: :alternative_title, label: 'Alternative title' },
    { field: :translated_title, label: 'Translated title' },
    { field: :uniform_title, label: 'Uniform title' },
    { field: :abbreviated_title, label: 'Abbreviated title' },
    { field: :languages, label: 'Languages' },
    { field: :date_created, render: :date_created },
    { field: :date_issued, render: :date_issued },
    { field: :copyright_date, render: :copyright_date },
    { field: :publication_information, label: 'Publisher' },
    { field: :place_of_publication, label: 'Place of publication' },
    { field: :edition, label: 'Edition' },
    { field: :issuance, label: 'Issuance', titleize: true },
    { field: :frequency, label: 'Frequency' },
    { field: :genres, label: 'Genres' },
    { field: :format, label: 'Format', titleize: true },
    { field: :extent, label: 'Extent' },
    { field: :digital_origin, label: 'Digital origin', titleize: true },
    { field: :reformatting_quality, label: 'Reformatting quality', titleize: true },
    { field: :abstract, render: :abstract },
    { field: :table_of_contents, label: 'Contents' },
    { field: :notes, render: :notes },
    { field: :related_series, label: 'Series' },
    { field: :host_collections, label: 'Host collections' },
    { field: :related_items, render: :related_items },
    { field: :topical_subjects, label: 'Subjects and keywords' },
    { field: :geographic_subjects, label: 'Places' },
    { field: :hierarchical_geographic_subjects, render: :hierarchical_geographic_subjects },
    { field: :geographic_code_subjects, label: 'Geographic codes' },
    { field: :temporal_subjects, label: 'Time periods' },
    { field: :personal_name_subjects, label: 'People' },
    { field: :corporate_name_subjects, label: 'Organizations' },
    { field: :genre_subjects, label: 'Subject genres' },
    { field: :title_subjects, label: 'Subject titles' },
    { field: :map_data, render: :map_data },
    { field: :identifiers, render: :identifiers },
    { field: :classification, label: 'Photo category' },
    { field: :permanent_url, label: 'Permanent URL', link: true },
    { field: :location, render: :location },
    { field: :use_and_reproduction, label: 'Use and reproduction', link: true },
    { field: :restriction_on_access, label: 'Restriction on access', link: true },
    { field: :access_condition, render: :access_condition }
  ].freeze

  # Projected fields with no row of their own, listed so the coverage spec can
  # tell a deliberate omission from a forgotten one.
  #
  # None of the date parts is a value a reader wants on its own: the precisions
  # choose the format, the end value and the qualifier are composed into the
  # date string, and the key-date flag chooses which date sorts.
  #
  # record_info is cataloguing and preservation provenance rather than a
  # description of the resource, so it renders nowhere: v1 hardcoded it on every
  # load, and five rows of identical text beside Publisher buy a reader nothing.
  # It is still projected onto the access copy rather than left in the
  # preservation XML alone, so the API and the OAI crosswalk can read that
  # provenance without a Nokogiri parse on a read path.
  #
  # resource_type is a closed vocabulary of about ten values that tells a reader
  # what they can already see: a photograph's record says "still image", and the
  # Content facet answers the same question in the words a reader uses. It stays
  # projected and indexed, because dc:type wants exactly this controlled
  # vocabulary and a harvester has no picture in front of it.
  NOT_DISPLAYED = %i[
    record_info
    resource_type
    date_created_precision date_created_end date_created_end_precision
    date_created_qualifier date_created_key_date
    date_issued_precision date_issued_end date_issued_end_precision
    date_issued_qualifier date_issued_key_date
    copyright_date_precision copyright_date_end copyright_date_end_precision
    copyright_date_qualifier copyright_date_key_date
  ].freeze

  # A date renders only as finely as the record declared it. A year-only date
  # parses to 1 January, so a hardcoded '%Y-%m-%d' would print a month and a day
  # the record never claimed, indistinguishable from one that did. An absent or
  # unrecognised precision keeps the full-date format, so a record stored before
  # the gem carried precision renders exactly as it used to.
  DATE_FORMATS = { 'year' => '%Y', 'month' => '%Y-%m', 'day' => '%Y-%m-%d' }.freeze

  # A qualifier changes the string a reader sees, not a tooltip. These are the
  # conventions cataloguers already use, so they read as intended rather than
  # as a rendering bug. Hiding the doubt in a title attribute leaves a reader
  # scanning the page with a bare date they take as certain, and a screen
  # reader may not announce it at all.
  DATE_QUALIFIERS = {
    'approximate'  => ->(rendered) { "circa #{rendered}" },
    'inferred'     => ->(rendered) { "[#{rendered}]" },
    'questionable' => ->(rendered) { "#{rendered}?" }
  }.freeze

  # The label for a name that declares no role. MODS makes mods:role optional,
  # and a nil label rendered an empty <dt>, so the name read as a value of the
  # field above it and a screen reader announced it under an empty term. v1
  # labelled these "Creator", so this restores a convention rather than
  # inventing one; a role-less name merges with an explicit Creator group.
  NO_ROLE_LABEL = 'Creator'

  # hierarchicalGeographic levels, broadest to narrowest. Reversed for display
  # and read from the narrow end for the facet, so a record naming a city is
  # browsed by its city rather than by its continent.
  PLACE_LEVELS = %i[continent country province region state territory county
                    island city city_section area].freeze

  def mods_rows
    safe_join(DISPLAY.map { |row| mods_row(row[:field]) })
  end

  # One field's markup, addressable by name so a decorator spec can assert a
  # single row and a failure names the field that regressed.
  def mods_row(name)
    row = DISPLAY.find { |candidate| candidate[:field] == name }
    return '' if row.nil?
    return public_send(row[:render]) if row[:render]

    render_plain_row(row)
  end

  def names
    return '' if mods&.names.blank?

    grouped = mods.names.each_with_object({}) do |pn, hsh|
      (hsh[MarcRelators.label(pn.role) || NO_ROLE_LABEL] ||= []) << name_with_affiliation(pn)
    end
    safe_join(grouped.map { |label, values| loop_field(label, values) })
  end

  # The type leads the value, because a DOI and a local accession number are
  # not the same kind of thing and a reader cannot tell them apart from the
  # digits. Upcased rather than titleized: these are codes, so "DOI" reads
  # right where "Doi" does not.
  def identifiers
    values = Array(mods&.identifiers).filter_map do |entry|
      next if entry.value.blank?

      entry.type.present? ? "#{entry.type.upcase}: #{entry.value}" : entry.value
    end
    loop_field('Identifiers', values)
  end

  # Most specific first, which is the MODS display convention and the order a
  # reader reads a place in: "Parksville, New York, United States". The absent
  # levels are skipped rather than emitting separators for them.
  def hierarchical_geographic_subjects
    values = Array(mods&.hierarchical_geographic_subjects).filter_map do |entry|
      parts = PLACE_LEVELS.reverse.filter_map { |level| entry.public_send(level).presence }
      parts.join(', ') if parts.any?
    end
    loop_field('Places', values)
  end

  def date_created = mods_date('Date created', :date_created)
  def date_issued = mods_date('Date issued', :date_issued)
  def copyright_date = mods_date('Copyright date', :copyright_date)

  # Notes group under their @type, the way names group under their role: a
  # statement of responsibility and a funding note are different things, and
  # rendering them under one heading would say they are not. An untyped note
  # keeps the generic label.
  def notes
    return '' if mods&.notes.blank?

    grouped = mods.notes.each_with_object({}) do |note, hsh|
      (hsh[note.type.presence&.humanize || 'Notes'] ||= []) << note.value
    end
    safe_join(grouped.map { |label, values| loop_field(label, values) })
  end

  # relatedItem types that have no field of their own. The type leads the value
  # because "the print edition" and "reviewed in" are different relationships
  # and the title alone cannot tell a reader which one this is.
  def related_items
    values = Array(mods&.related_items).filter_map do |item|
      next if item.title.blank?

      item.type.present? ? "#{item.type.titleize}: #{item.title}" : item.title
    end
    loop_field('Related items', values)
  end

  # A location's parts render as separate values so linkify sees the URL as a
  # URL and the shelf mark as text. Flattened across locations because a reader
  # wants the places, not the record's grouping of them.
  def location
    values = Array(mods&.location).flat_map do |loc|
      [loc.physical_location, loc.shelf_location, loc.url]
    end
    loop_field('Location', values.compact_blank)
  end

  # Composing "scale ; projection coordinates" is display policy, which is why
  # the gem leaves cartographics structured and it happens here. The separator
  # follows the MODS display convention.
  def map_data
    values = Array(mods&.map_data).filter_map do |entry|
      scale = entry.scale.presence || 'Scale not given'
      rest = [entry.projection, entry.coordinates].compact_blank.join(' ')
      rest.present? ? "#{scale} ; #{rest}" : scale
    end
    loop_field('Map data', values)
  end

  # The combined accessCondition is the only value carrying an untyped one, so
  # it renders only when neither typed field claimed anything. Otherwise a
  # record with a licence would show the same text twice.
  def access_condition
    return '' if mods&.use_and_reproduction.present? || mods&.restriction_on_access.present?

    field('Access condition', mods&.access_condition, link: true)
  end

  private

    def render_plain_row(row)
      value = mods&.public_send(row[:field])
      return loop_field(row[:label], transform(value, row)) if NEU::MODS::FIELDS[row[:field]] == :many

      field(row[:label], transform(value, row), link: row.fetch(:link, false))
    end

    def transform(value, row)
      return value unless row[:titleize]

      value.is_a?(Array) ? value.map(&:titleize) : value&.titleize
    end

    # A date renders everything the record declared about it: the value at its
    # own granularity, the other end of a range at the end's own granularity,
    # and the qualifier around the whole thing. "circa 1935-1940" is honest
    # where "1935" and "1935-1940" both are not.
    def mods_date(label, attribute)
      value = mods&.public_send(attribute)
      return field(label, nil) if value.blank?

      rendered = [formatted_date(value, part(attribute, 'precision')),
                  formatted_date(part(attribute, 'end'), part(attribute, 'end_precision'))]
                 .compact_blank.join('-')
      field(label, qualified(rendered, part(attribute, 'qualifier')))
    end

    def part(attribute, name) = mods.public_send(:"#{attribute}_#{name}")

    def formatted_date(value, precision)
      return nil if value.blank?

      value.strftime(DATE_FORMATS.fetch(precision, '%Y-%m-%d'))
    end

    # An unrecognised qualifier is shown rather than dropped, the rule the gem
    # applies to an unknown language code: the record still said something.
    def qualified(rendered, qualifier)
      return rendered if qualifier.blank?

      formatter = DATE_QUALIFIERS[qualifier]
      formatter ? formatter.call(rendered) : "#{rendered} (#{qualifier})"
    end

    # The affiliation attaches to the name it belongs to and never becomes a
    # grouping key: two physicists in different departments still belong under
    # one Creator heading.
    def name_with_affiliation(entry)
      affiliation = Array(entry.affiliation).compact_blank
      return entry.name if affiliation.empty?

      "#{entry.name} — #{affiliation.join(', ')}"
    end
end
