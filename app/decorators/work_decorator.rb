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
    { field: :physical_description_notes, label: 'Physical description note' },
    { field: :abstract, render: :abstract },
    { field: :table_of_contents, label: 'Contents' },
    { field: :notes, render: :notes },
    { field: :related_series, label: 'Series' },
    { field: :host_collections, render: :host_collections },
    { field: :related_items, render: :related_items },
    { field: :subject_headings, render: :subject_headings },
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
  # Four whole dates render nowhere either. dateCaptured is when the object was
  # digitised and dateModified is when the resource changed -- preservation and
  # cataloguing provenance rather than description, so they follow record_info
  # below. dateValid and dateOther are descriptive, and a librarian decided
  # against a row for both: neither answers a question a reader of this
  # repository asks, and dateOther means whatever the cataloguer meant. All
  # four stay projected, so the API and the OAI crosswalk can read them.
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
  # The subject axes have no row because #subject_headings renders them, joined
  # back into the heading the cataloguer built. Split apart they asserted
  # independent subjects the record never claimed: one LCSH heading became rows
  # under three labels, and the string a cataloguer typed appeared nowhere. They
  # stay projected because the Solr facets and the OAI crosswalk read them --
  # those consumers want the parts, and a reader wants the heading.
  #
  # geographic_code_subjects is the exception within the exception: a MARC GAC
  # code is not heading text, so it is neither a row nor a part of one.
  NOT_DISPLAYED = %i[
    record_info
    resource_type
    topical_subjects geographic_subjects temporal_subjects
    personal_name_subjects corporate_name_subjects occupation_subjects
    genre_subjects geographic_code_subjects title_subjects
    hierarchical_geographic_subjects
    date_created_precision date_created_end date_created_end_precision
    date_created_qualifier date_created_key_date
    date_issued_precision date_issued_end date_issued_end_precision
    date_issued_qualifier date_issued_key_date
    copyright_date_precision copyright_date_end copyright_date_end_precision
    copyright_date_qualifier copyright_date_key_date
    date_captured date_captured_precision date_captured_end
    date_captured_end_precision date_captured_qualifier date_captured_key_date
    date_valid date_valid_precision date_valid_end
    date_valid_end_precision date_valid_qualifier date_valid_key_date
    date_other date_other_precision date_other_end
    date_other_end_precision date_other_qualifier date_other_key_date
    date_modified date_modified_precision date_modified_end
    date_modified_end_precision date_modified_qualifier date_modified_key_date
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

  # hierarchicalGeographic levels, broadest to narrowest. MODSIndexer reads them
  # from the narrow end, so a record naming a city is browsed by its city rather
  # than by its continent.
  PLACE_LEVELS = %i[continent country province region state territory county
                    island city city_section area].freeze

  # The separator a cataloguer builds an LCSH heading with, and the one v1 ran
  # for years. Display policy, so it lives here rather than in the gem.
  SUBJECT_HEADING_SEPARATOR = ' -- '

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

  # A name appears under every role it declares. A person recorded as both
  # author and contributor is two assertions, so the repetition is what the
  # record says rather than a duplicate.
  def names
    return '' if mods&.names.blank?

    grouped = mods.names.each_with_object({}) do |pn, hsh|
      labels = Array(pn.roles).filter_map { |role| MarcRelators.label(role) }.presence || [NO_ROLE_LABEL]
      labels.each { |label| (hsh[label] ||= []) << name_with_affiliation(pn) }
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
  # One row per subject, its parts joined back into the heading a cataloguer
  # built. The parts also render as facets, which is why the gem keeps them
  # apart and this joins them: a facet wants "Massachusetts", a reader wants
  # "Salt marshes -- Massachusetts -- 20th century".
  def subject_headings
    values = Array(mods&.subject_headings).filter_map do |heading|
      Array(heading.parts).compact_blank.join(SUBJECT_HEADING_SEPARATOR).presence
    end
    loop_field('Subjects and keywords', values)
  end

  # "Estuaries, 24(3), pp. 210-218". The host's editor, publisher and ISSN stay
  # out: they are the other record's metadata, and a reader who wants them
  # should reach that record rather than read a copy that goes stale.
  def host_collections
    values = Array(mods&.host_collections).filter_map do |host|
      next if host.title.blank?

      [host.title, host_position(host)].compact_blank.join(', ')
    end
    loop_field('Host collections', values)
  end

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

    # Volume, issue and pages in citation order. Every part is optional, so a
    # record giving only a page range renders only that.
    def host_position(host)
      volume = [host.volume, host.issue.presence && "(#{host.issue})"].compact_blank.join
      [volume.presence, host_pages(host)].compact_blank.join(', ')
    end

    def host_pages(host)
      return nil if host.start_page.blank?

      host.end_page.present? ? "pp. #{host.start_page}-#{host.end_page}" : "p. #{host.start_page}"
    end

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
