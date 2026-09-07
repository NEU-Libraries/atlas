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
  # title, a date formatted to its declared precision. :capitalize and :link
  # are the two per-value transforms plain rows need.
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
    { field: :languages, render: :languages },
    { field: :date_created, render: :date_created },
    { field: :date_issued, render: :date_issued },
    { field: :copyright_date, render: :copyright_date },
    { field: :publication_information, label: 'Publisher' },
    { field: :place_of_publication, label: 'Place of publication' },
    { field: :edition, label: 'Edition' },
    { field: :issuance, label: 'Issuance', capitalize: true },
    { field: :frequency, label: 'Frequency' },
    { field: :genres, label: 'Genres' },
    { field: :format, label: 'Format', capitalize: true },
    { field: :extent, label: 'Extent' },
    { field: :digital_origin, label: 'Digital origin', capitalize: true },
    { field: :reformatting_quality, label: 'Reformatting quality', capitalize: true },
    { field: :physical_description_notes, label: 'Physical description note' },
    { field: :abstract, render: :abstract },
    { field: :table_of_contents, render: :table_of_contents },
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
  # date string, the key-date flag chooses which date sorts, and the text
  # carries the literal a record wrote in something other than w3cdtf, which
  # the date row renders when there is no date to format.
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
    date_created_qualifier date_created_key_date date_created_text
    date_issued_precision date_issued_end date_issued_end_precision
    date_issued_qualifier date_issued_key_date date_issued_text
    copyright_date_precision copyright_date_end copyright_date_end_precision
    copyright_date_qualifier copyright_date_key_date copyright_date_text
    date_captured date_captured_precision date_captured_end
    date_captured_end_precision date_captured_qualifier date_captured_key_date
    date_captured_text
    date_valid date_valid_precision date_valid_end
    date_valid_end_precision date_valid_qualifier date_valid_key_date
    date_valid_text
    date_other date_other_precision date_other_end
    date_other_end_precision date_other_qualifier date_other_key_date
    date_other_text
    date_modified date_modified_precision date_modified_end
    date_modified_end_precision date_modified_qualifier date_modified_key_date
    date_modified_text
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

  # How a date that is an end with no beginning reads. `<dateCreated
  # point="end">1921</>` says the resource is no later than 1921 and nothing
  # more, so the bare year would assert a date the record refused to give.
  END_ONLY_DATE_PREFIX = 'before'

  # The label for a name that declares no role. MODS makes mods:role optional,
  # and a nil label rendered an empty <dt>, so the name read as a value of the
  # field above it and a screen reader announced it under an empty term. v1
  # labelled these "Creator", so this restores a convention rather than
  # inventing one; a role-less name merges with an explicit Creator group.
  NO_ROLE_LABEL = 'Creator'

  # The label for a name whose role is a MARC code this system does not hold.
  # An unlisted code fell through to itself, so a typo'd "zzz" became a row
  # heading -- exactly the outcome suppressing displayLabel exists to prevent,
  # since labels come from one list the system controls. The name still
  # renders, because losing it over a typo is worse than filing it loosely, and
  # it is kept apart from Creator because the record did not say creator.
  UNKNOWN_ROLE_LABEL = 'Other contributors'

  # hierarchicalGeographic levels, broadest to narrowest. MODSIndexer reads them
  # from the narrow end, so a record naming a city is browsed by its city rather
  # than by its continent.
  PLACE_LEVELS = %i[continent country province region state territory county
                    island city city_section area].freeze

  # The separator a cataloguer builds an LCSH heading with, and the one v1 ran
  # for years. Display policy, so it lives here rather than in the gem.
  SUBJECT_HEADING_SEPARATOR = ' -- '

  # What follows an identifier the record flagged invalid. Words rather than a
  # symbol, and beside the value rather than in a tooltip, for the reason
  # DATE_QUALIFIERS gives: a reader scanning the page must not take a dead
  # number for a live one, and a screen reader may not announce an attribute.
  INVALID_IDENTIFIER_MARK = '(invalid)'

  # The separator between a map's scale, projection and coordinates, which is
  # the MODS display convention. Display policy, so it lives here rather than
  # in the gem.
  MAP_DATA_SEPARATOR = ' ; '

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
  # A nameless name is skipped. neu-mods drops one now, but an access copy
  # stored before that still carries { name: nil, roles: ["edt"] }, which
  # rendered a labelled empty row -- the guard #identifiers, #related_items and
  # #host_collections all already have.
  def names
    return '' if mods&.names.blank?

    grouped = mods.names.each_with_object({}) do |pn, hsh|
      next if pn.name.blank?

      name_labels(pn).each { |label| (hsh[label] ||= []) << name_with_affiliation(pn) }
    end
    safe_join(grouped.map { |label, values| loop_field(label, values) })
  end

  # The type leads the value, because a DOI and a local accession number are
  # not the same kind of thing and a reader cannot tell them apart from the
  # digits. Upcased rather than titleized: these are codes, so "DOI" reads
  # right where "Doi" does not.
  #
  # An identifier the record calls invalid is marked, not suppressed. In MODS
  # the attribute means cancelled, superseded or wrong, and a cancelled ISBN is
  # exactly what a reader chasing an old citation has in hand -- so it is worth
  # showing, and worth saying it will not resolve.
  def identifiers
    values = Array(mods&.identifiers).filter_map do |entry|
      next if entry.value.blank?

      rendered = entry.type.present? ? "#{entry.type.upcase}: #{entry.value}" : entry.value
      entry.invalid ? "#{rendered} #{INVALID_IDENTIFIER_MARK}" : rendered
    end
    loop_field('Identifiers', values)
  end

  # "Spanish (subtitles)". An @objectPart says the language belongs to part of
  # the object, not to the object -- a captioned video is not in the language
  # of its captions -- so the row must carry the qualification or it makes a
  # claim the record did not. The Solr facet still gets the bare term, so a
  # search for Spanish finds this record either way.
  #
  # The script joins the same parenthesis. It qualifies the term for the same
  # reason and a second bracket beside the first would read as two things.
  def languages
    values = Array(mods&.languages).filter_map do |entry|
      next if entry.term.blank?

      qualifiers = [entry.object_part, entry.script].compact_blank
      qualifiers.empty? ? entry.term : "#{entry.term} (#{qualifiers.join(', ')})"
    end
    loop_field('Languages', values)
  end

  # One <dd> per entry. The gem keeps a legacy contents list's line breaks
  # because there the break is the structure, and linkify would collapse a lone
  # newline back into a space -- so the lines are split here and rendered as
  # the list they are.
  def table_of_contents
    values = Array(mods&.table_of_contents).flat_map { |entry| entry.to_s.split("\n") }
    loop_field('Contents', values.compact_blank)
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
  #
  # Only a TOP-LEVEL relatedItem reaches here: the gem scopes its XPath to the
  # document root, so a relatedItem nested inside another does not display.
  # That is the same call as suppressing a host's own metadata -- it describes
  # the other record, not this one.
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

  # "Estuaries, 24(3), pp. 210-218, 1998". The host's editor, publisher and
  # ISSN stay out: they are the other record's metadata, and a reader who wants
  # them should reach that record rather than read a copy that goes stale.
  #
  # A host that names no title renders its position alone. The position
  # describes this work and no other record holds it, so dropping it because
  # the host block carried no titleInfo would lose the one part that was ours.
  def host_collections
    values = Array(mods&.host_collections).filter_map do |host|
      [host.title, host_position(host)].compact_blank.join(', ').presence
    end
    loop_field('Host collections', values)
  end

  # Composing "scale ; projection ; coordinates" is display policy, which is
  # why the gem leaves cartographics structured and it happens here. The
  # separator follows the MODS display convention.
  #
  # Every part takes it. Projection and coordinates shared one slot and
  # collided on a space, so a reader could not see where the projection name
  # ended and the coordinates began.
  #
  # A record that gave no scale gets no scale. Printing "Scale not given" put
  # an editorial complaint on a geotagged photograph that never claimed to have
  # one -- the mistake DATE_FORMATS above exists to avoid, in a new place.
  def map_data
    values = Array(mods&.map_data).filter_map do |entry|
      [entry.scale, entry.projection, entry.coordinates].compact_blank.join(MAP_DATA_SEPARATOR).presence
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

    # The whole of this work's position in its host, in citation order. Every
    # part is optional, so a record giving only a page range renders only that.
    def host_position(host)
      [host_number(host), host_pages(host), host_details(host), host_extents(host), host.date]
        .compact_blank.join(', ')
    end

    # "24(3)" for a volume and an issue together. A bare "(3)" reads as an
    # issue only when a volume precedes it, so an issue standing alone takes
    # the spelled-out form instead of a naked parenthesis.
    def host_number(host)
      return "#{host.volume}(#{host.issue})" if host.volume.present? && host.issue.present?
      return host.volume if host.volume.present?

      host.issue.presence && "no. #{host.issue}"
    end

    def host_pages(host)
      return nil if host.start_page.blank?

      host.end_page.present? ? "pp. #{host.start_page}-#{host.end_page}" : "p. #{host.start_page}"
    end

    # A detail beyond volume and issue: "chap. 7" from the caption a cataloguer
    # wrote, falling back to the @type when they wrote none. detail/@type is an
    # open string, so the type is the only label available for an unforeseen one.
    def host_details(host)
      Array(host.details).filter_map do |detail|
        numbered = [detail.caption.presence || detail.type&.titleize, detail.number].compact_blank.join(' ')
        [numbered.presence, detail.title].compact_blank.join(', ').presence
      end.join(', ')
    end

    # "minutes 0-45". An extent at a unit other than page means nothing without
    # its unit, so the unit leads the numbers rather than being dropped.
    def host_extents(host)
      Array(host.extents).filter_map do |extent|
        span = [extent.start, extent.end].compact_blank.join('-')
        [extent.unit, span.presence || extent.total || extent.list].compact_blank.join(' ').presence
      end.join(', ')
    end

    # The labels one name files under. A name declaring no role at all takes
    # the Creator default; a name whose roles are all unrecognised takes the
    # unknown-role label.
    #
    # The unknown-role label is a LAST resort, not a per-role one. A name
    # carrying "aut" and a typo'd "qqq" was filed under both, so a reader saw
    # the same person twice -- the second time under a role the record never
    # asserted. A name with at least one role this system knows is already
    # filed correctly, and the unrecognised code adds nothing but the
    # duplicate.
    def name_labels(entry)
      roles = Array(entry.roles).compact_blank
      return [NO_ROLE_LABEL] if roles.empty?

      known = roles.reject { |role| MarcRelators.unknown_code?(role) }
                   .filter_map { |role| MarcRelators.label(role) }.uniq
      known.presence || [UNKNOWN_ROLE_LABEL]
    end

    def render_plain_row(row)
      value = mods&.public_send(row[:field])
      return loop_field(row[:label], transform(value, row)) if NEU::MODS::FIELDS[row[:field]] == :many

      field(row[:label], transform(value, row), link: row.fetch(:link, false))
    end

    # The first letter is upcased and the rest of the term is left alone.
    # titleize split on hyphens and capitalised every word, so the authorised
    # AAT form "black-and-white negatives" was rewritten to "Black And White
    # Negatives" -- a term that is not in the vocabulary and not the one the
    # cataloguer typed. physicalDescription/form takes authority terms, and the
    # siblings a reader compares it against (extent, genres) are untouched.
    def transform(value, row)
      return value unless row[:capitalize]

      value.is_a?(Array) ? value.map { |member| member&.upcase_first } : value&.upcase_first
    end

    # A date renders everything the record declared about it: the value at its
    # own granularity, the other end of a range at the end's own granularity,
    # and the qualifier around the whole thing. "circa 1935-1940" is honest
    # where "1935" and "1935-1940" both are not.
    #
    # A record whose date is not a w3cdtf one has no value to format, and the
    # gem hands over the literal instead. Showing "19uu" is what the record
    # says; the alternative is a row a cataloguer filled in that no reader ever
    # sees.
    def mods_date(label, attribute)
      return field(label, part(attribute, 'text')) unless dated?(attribute)

      field(label, composed_date(attribute))
    end

    # Whether the record gave a date this can format. An end point with no
    # beginning counts: "sometime before 1921" is a real encoding and the whole
    # date some records have.
    def dated?(attribute)
      mods&.public_send(attribute).present? || part(attribute, 'end').present?
    end

    # "1935-06-1940", "circa 1935" or "before circa 1921". An end standing
    # alone is spelled out, because a leading hyphen reads as a typo and the
    # bare year would assert a date the record did not give. The prefix sits
    # OUTSIDE the qualifier so the two read as English in that order.
    def composed_date(attribute)
      start = formatted_date(mods.public_send(attribute), part(attribute, 'precision'))
      finish = formatted_date(part(attribute, 'end'), part(attribute, 'end_precision'))
      qualifier = part(attribute, 'qualifier')
      return "#{END_ONLY_DATE_PREFIX} #{qualified(finish, qualifier)}" if start.blank?

      qualified([start, finish].compact_blank.join('-'), qualifier)
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
