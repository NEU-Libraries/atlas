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
  # The order is the librarians' own: identity elements, then discovery
  # elements, then utility elements.
  #
  # :label is what a reader sees WHEN the record asks for nothing else -- a
  # record's own @displayLabel outranks it, and inside an originInfo block so
  # does @eventType. :render names a method for a field whose markup is more
  # than a label and a value. :within names the row that renders this field
  # instead, for a field the librarians asked to show with no header of its
  # own. :capitalize is the one per-value transform a plain row needs; a link
  # now rides on the value, so :link is gone. :axis names the browse a plain
  # row's values belong to, for a consumer that turns them into search links.
  #
  # Labels live here and not in neu-mods on purpose. A label is display
  # vocabulary, and Cerberus's edit form words the same field differently; the
  # gem owns what a field IS, this owns what it looks like.
  DISPLAY = [
    # Identity
    { field: :main_title, render: :title },
    { field: :alternative_title, label: 'Alternative title' },
    { field: :translated_title, label: 'Translated title' },
    { field: :uniform_title, label: 'Uniform title' },
    { field: :abbreviated_title, label: 'Abbreviated title' },
    { field: :names, render: :names },
    { field: :publication_information, render: :publication_information },
    { field: :place_of_publication, render: :place_of_publication },
    { field: :origin_agents, render: :origin_agents },
    { field: :edition, label: 'Edition' },
    { field: :issuance, label: 'Issuance', capitalize: true },
    { field: :frequency, label: 'Frequency' },
    { field: :date_created, render: :date_created },
    { field: :date_issued, render: :date_issued },
    { field: :copyright_date, render: :copyright_date },

    # Discovery
    { field: :genres, label: 'Genres', axis: MODSBrowse::GENRE },
    { field: :table_of_contents, render: :table_of_contents },
    { field: :abstract, render: :abstract },
    { field: :notes, render: :notes },
    { field: :target_audience, label: 'Target audience' },
    { field: :subject_headings, render: :subject_headings },
    { field: :map_data, render: :map_data },
    { field: :classification, label: 'Photo category', axis: MODSBrowse::PHOTO_CATEGORY },
    { field: :resource_type, label: 'Type of resource', capitalize: true },

    # Utility
    { field: :extent, render: :physical_description },
    { field: :digital_origin, within: :extent },
    { field: :reformatting_quality, label: 'Reformatting quality', capitalize: true },
    { field: :physical_description_notes, label: 'Physical description note' },
    { field: :languages, render: :languages },
    { field: :related_series, label: 'Series' },
    { field: :host_collections, render: :host_collections },
    { field: :related_items, render: :related_items },
    { field: :location, render: :location },
    { field: :identifiers, render: :identifiers },
    { field: :permanent_url, render: :permanent_url },
    { field: :use_and_reproduction, render: :use_and_reproduction },
    { field: :restriction_on_access, render: :restriction_on_access },
    { field: :access_condition, render: :access_condition }
  ].freeze

  # The parts every projected date carries beside its value, none of them a row
  # of its own: the precisions choose the format, the end value and the
  # qualifier are composed into the date string, the key-date flag chooses
  # which date sorts, the text carries the literal a record wrote in something
  # other than w3cdtf, and the label and the event type head the row rather
  # than fill it. Derived rather than written out -- seven dates times eight
  # parts is fifty-six near-identical lines.
  DATE_PARTS = %w[precision end end_precision qualifier key_date text
                  display_label event_type].freeze

  DATE_PARTS_NOT_DISPLAYED = NEU::MODS::FIELDS.keys.grep(/_key_date\z/).flat_map do |flag|
    prefix = flag.to_s.delete_suffix('_key_date')
    DATE_PARTS.map { |part| :"#{prefix}_#{part}" }
  end.freeze

  # Projected fields with no row of their own, listed so the coverage spec can
  # tell a deliberate omission from a forgotten one.
  #
  # Four whole dates render nowhere. dateCaptured is when the object was
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
  # physicalDescription/form renders nowhere by the librarians' decision: it
  # duplicates the extent and the digital origin beside it in vocabulary a
  # reader does not use. It stays projected and stays in the preservation XML.
  #
  # The subject axes have no row because #subject_headings renders them, joined
  # back into the heading the cataloguer built. Split apart they asserted
  # independent subjects the record never claimed: one LCSH heading became rows
  # under three labels, and the string a cataloguer typed appeared nowhere.
  # They stay projected for the OAI crosswalk, which wants discrete terms a
  # harvester can match. The Solr facets no longer read them: a facet holds the
  # whole heading now, so the string a reader clicks is the string the index
  # holds.
  #
  # geographic_code_subjects is the exception within the exception: a MARC GAC
  # code is not heading text, so it is neither a row nor a part of one.
  #
  # The six companion labels and links fill a header rather than a row: each is
  # read by the row of the field it names, the way the date parts above are.
  NOT_DISPLAYED = (%i[
    record_info
    format
    topical_subjects geographic_subjects temporal_subjects
    personal_name_subjects corporate_name_subjects occupation_subjects
    genre_subjects geographic_code_subjects title_subjects
    hierarchical_geographic_subjects
    date_captured date_valid date_other date_modified
    main_title_display_label
    abstract_display_label abstract_href
    permanent_url_display_label
    access_condition_display_label access_condition_href
    use_and_reproduction_display_label use_and_reproduction_href
    restriction_on_access_display_label restriction_on_access_href
  ] + DATE_PARTS_NOT_DISPLAYED).freeze

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

  # The label for a role-less name that LEADS. MODS makes mods:role optional,
  # and a nil label rendered an empty <dt>, so the name read as a value of the
  # field above it and a screen reader announced it under an empty term. v1
  # labelled these "Creator", so this restores a convention rather than
  # inventing one; a role-less lead merges with an explicit Creator group.
  NO_ROLE_LABEL = 'Creator'

  # Where the role-less names that do NOT lead go. A record listing six names
  # and marking none of them said one thing: these people were involved. Filing
  # all six as creators asserts six creators, which is the claim the librarians
  # asked to stop making.
  TRAILING_NAME_LABEL = 'Contributor'

  # The label for a name whose role is a MARC code this system does not hold.
  # A heading comes from one list the system controls, so an unlisted code must
  # not become one -- that is the outcome suppressing displayLabel exists to
  # prevent. The name still renders, because losing it over a typo is worse
  # than filing it loosely, and it is kept apart from Creator because the
  # record did not say creator.
  #
  # The code itself is shown nowhere, and that is settled rather than pending.
  # A curator proofing a record reads the XML for what the record literally
  # says; a reader has no use for a relator code this system cannot name.
  UNKNOWN_ROLE_LABEL = 'Other contributors'

  # What a name's @usage has to say to nominate itself. Fixed in the schema, so
  # there is exactly one value to match.
  PRIMARY_USAGE = 'primary'

  # hierarchicalGeographic levels, broadest to narrowest. MODSIndexer reads them
  # from the narrow end, so a record naming a city is browsed by its city rather
  # than by its continent.
  PLACE_LEVELS = %i[continent country province region state territory county
                    island city city_section area].freeze

  # What follows an identifier the record flagged invalid. Words rather than a
  # symbol, and beside the value rather than in a tooltip, for the reason
  # DATE_QUALIFIERS gives: a reader scanning the page must not take a dead
  # number for a live one, and a screen reader may not announce an attribute.
  INVALID_IDENTIFIER_MARK = '(invalid)'

  # The separator between a map's scale, projection and coordinates, which is
  # the MODS display convention. Display policy, so it lives here rather than
  # in the gem.
  MAP_DATA_SEPARATOR = ' ; '

  # The default headers a row falls back to when the record asks for none.
  PUBLISHER_LABEL = 'Publisher'
  PHYSICAL_DESCRIPTION_LABEL = 'Physical description'
  LANGUAGES_LABEL = 'Languages'
  CONTENTS_LABEL = 'Contents'
  NOTES_LABEL = 'Notes'
  SUBJECTS_LABEL = 'Subjects and keywords'
  MAP_DATA_LABEL = 'Map data'
  LOCATION_LABEL = 'Physical location'
  IDENTIFIERS_LABEL = 'Identifiers'
  PERMANENT_URL_LABEL = 'Permanent URL'
  USE_AND_REPRODUCTION_LABEL = 'Use and reproduction'
  RESTRICTION_ON_ACCESS_LABEL = 'Restriction on access'
  ACCESS_CONDITION_LABEL = 'Access condition'

  # A place is headed by the date beside it: the same element records where a
  # thing was made and where it was published, and only the block's date says
  # which. dateIssued leads, so a block carrying both reads as a publication.
  PLACE_LABELS = { 'dateIssued' => 'Publication place', 'dateCreated' => 'Creation place' }.freeze

  # A dateless block still has to head its place, and the librarians chose the
  # publication reading -- which is also what the field was called before.
  DEFAULT_PLACE_LABEL = 'Publication place'

  # relatedItem/@type in the words the librarians chose, keyed on a folded type
  # so a record's casing cannot decide whether a heading is found. series is
  # absent on purpose: its wording is still open, so it keeps the row and the
  # label it already had.
  RELATED_ITEM_LABELS = {
    'host'           => 'Host collection',
    'constituent'    => 'Includes',
    'otherversion'   => 'Other versions',
    'otherformat'    => 'Other formats',
    'preceding'      => 'Preceded by',
    'succeeding'     => 'Continued by',
    'original'       => 'Original version',
    'isreferencedby' => 'Cited by'
  }.freeze

  # A relatedItem whose type this list does not name. The type is no longer
  # prefixed onto the value: a heading a reader can read beats a camelCased
  # attribute titleized into one.
  GENERIC_RELATED_ITEM_LABEL = 'Related resources'

  # The controlled digitalOrigin terms in the words the librarians chose. The
  # MODS vocabulary describes a workflow ("reformatted digital"); these say what
  # a reader wants to know, which is whether they are looking at a scan.
  # An unlisted term renders as the record wrote it, capitalised -- the rule the
  # gem applies to an unknown language code: the record still said something.
  DIGITAL_ORIGIN_LABELS = {
    'reformatted digital'    => 'Digitized',
    'born digital'           => 'Born digital',
    'digitized microfilm'    => 'Digitized microfilm',
    'digitized other analog' => 'Digitized copy'
  }.freeze

  # What brackets an alternative name and an affiliation after the name. One
  # pair around both, because they qualify the same name and two brackets side
  # by side read as two separate things.
  NAME_QUALIFIER_SEPARATOR = ', '

  def mods_rows
    safe_join(DISPLAY.reject { |row| row[:within] }.map { |row| mods_row(row[:field]) })
  end

  # One field's markup, addressable by name so a decorator spec can assert a
  # single row and a failure names the field that regressed. A field rendered
  # inside another row answers with that row.
  def mods_row(name)
    row = DISPLAY.find { |candidate| candidate[:field] == name }
    return '' if row.nil?
    return mods_row(row[:within]) if row[:within]
    return public_send(row[:render]) if row[:render]

    render_plain_row(row)
  end

  # A name appears under every role it declares. A person recorded as both
  # author and contributor is two assertions, so the repetition is what the
  # record says rather than a duplicate.
  #
  # A nameless name is skipped. neu-mods drops one now, but an access copy
  # stored before that still carries { name: nil, roles: ["edt"] }, which
  # rendered a labelled empty row.
  def names
    entries = Array(mods&.names).reject { |entry| entry.name.blank? }
    return '' if entries.empty?

    # Not #grouped_rows: one name files under EVERY role it declares, and the
    # lead rule needs the name's position among the others.
    leads = leading_name_indexes(entries)
    grouped = entries.each_with_index.with_object({}) do |(entry, index), hsh|
      name_headers(entry, lead: leads.include?(index))
        .each { |label| (hsh[label] ||= []) << browse_name(entry) }
    end
    safe_join(grouped.map { |label, values| html_field(label, values) })
  end

  # The publisher row exists only where a publisher does, which is the whole of
  # the librarians' rule: the header is the record's own label, then its event
  # type, then "Publisher".
  def publication_information
    labeled_rows(PUBLISHER_LABEL, mods&.publication_information, axis: MODSBrowse::PUBLISHER)
  end

  # A place's header comes from the date beside it when the record names
  # neither a label nor an event.
  def place_of_publication
    grouped_rows(mods&.place_of_publication) do |entry|
      next if entry.value.blank?

      [place_header(entry),
       browse_value(entry.value, MODSBrowse::PLACE_OF_PUBLICATION, href: entry.href)]
    end
  end

  # originInfo/agent, new in MODS 3.8. Its roleTerm heads the row, exactly as a
  # top-level name's does, unless the block states a label or an event type.
  def origin_agents
    grouped_rows(mods&.origin_agents) do |entry|
      next if entry.name.blank?

      [agent_header(entry), linked_value(name_with_qualifiers(entry), entry.href)]
    end
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
    grouped_rows(mods&.identifiers) do |entry|
      next if entry.value.blank?

      [entry.display_label.presence || IDENTIFIERS_LABEL,
       linked_value(identifier_value(entry), entry.href)]
    end
  end

  def permanent_url
    labeled_field(mods&.permanent_url_display_label.presence || PERMANENT_URL_LABEL,
                  mods&.permanent_url)
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
    grouped_rows(mods&.languages) do |entry|
      next if entry.term.blank?

      [entry.display_label.presence || LANGUAGES_LABEL,
       browse_value(qualified_language(entry), MODSBrowse::LANGUAGE, value: entry.term,
                    authority: entry.authority, href: entry.href)]
    end
  end

  # One <dd> per entry. The gem keeps a legacy contents list's line breaks
  # because there the break is the structure, and linkify would collapse a lone
  # newline back into a space -- so the lines are split here and rendered as
  # the list they are.
  def table_of_contents
    grouped_rows(mods&.table_of_contents) do |entry|
      lines = entry.value.to_s.split("\n").compact_blank
      next if lines.empty?

      [header_for(entry, CONTENTS_LABEL), lines.map { |line| linked_value(line, entry.href) }]
    end
  end

  def date_created = mods_date('Date created', :date_created)
  def date_issued = mods_date('Date issued', :date_issued)
  def copyright_date = mods_date('Copyright date', :copyright_date)

  # Notes group under their @type, the way names group under their role: a
  # statement of responsibility and a funding note are different things, and
  # rendering them under one heading would say they are not. An untyped note
  # keeps the generic label, and a record's own label outranks both.
  def notes
    grouped_rows(mods&.notes) do |note|
      next if note.value.blank?

      [note.display_label.presence || note.type.presence&.humanize || NOTES_LABEL,
       linked_value(note.value, note.href)]
    end
  end

  # The extent and the digital origin under one header, which is what the
  # librarians asked for when they took the separate "Digital origin" heading
  # away. Whether that header should read "Technical details" is still open
  # with them, so it reads as the element is named.
  def physical_description
    labeled_rows(PHYSICAL_DESCRIPTION_LABEL, Array(mods&.extent) + digital_origin_entries)
  end

  # Only a TOP-LEVEL relatedItem reaches here: the gem scopes its XPath to the
  # document root, so a relatedItem nested inside another does not display.
  # That is the same call as suppressing a host's own metadata -- it describes
  # the other record, not this one.
  #
  # A relatedItem is headed by what the relationship IS. The type used to lead
  # the value ("Otherformat: the print edition"), which put a camelCased
  # attribute in front of a title and still left every relationship under one
  # heading.
  def related_items
    grouped_rows(mods&.related_items) do |item|
      next if item.title.blank?

      [related_item_header(item), linked_value(item.title, item.href)]
    end
  end

  # A location's parts render as separate values so linkify sees the URL as a
  # URL and the shelf mark as text. Flattened across locations because a reader
  # wants the places, not the record's grouping of them.
  def location
    grouped_rows(mods&.location) do |loc|
      values = [loc.physical_location, loc.shelf_location, loc.url].compact_blank
      next if values.empty?

      [loc.display_label.presence || LOCATION_LABEL,
       values.map { |value| linked_value(value, loc.href) }]
    end
  end

  # One row per subject, as the heading a cataloguer built. The row and the
  # facet now hold ONE string -- "Salt marshes -- Massachusetts -- 20th
  # century" is what a reader reads and what a browse of it returns -- so the
  # marker can name the value without a consumer matching on rendered text.
  def subject_headings
    grouped_rows(mods&.subject_headings) do |heading|
      composed = composed_heading(heading)
      next unless composed

      [heading.display_label.presence || SUBJECTS_LABEL,
       browse_value(composed, MODSBrowse.subject_axis(heading),
                    authority: heading.authority, href: heading.href)]
    end
  end

  # "Estuaries, 24(3), pp. 210-218, 1998". The host's editor, publisher and
  # ISSN stay out: they are the other record's metadata, and a reader who wants
  # them should reach that record rather than read a copy that goes stale.
  #
  # A host that names no title renders its position alone. The position
  # describes this work and no other record holds it, so dropping it because
  # the host block carried no titleInfo would lose the one part that was ours.
  def host_collections
    grouped_rows(mods&.host_collections) do |host|
      composed = [host.title, host_position(host)].compact_blank.join(', ').presence
      next unless composed

      [host.display_label.presence || RELATED_ITEM_LABELS['host'], linked_value(composed, host.href)]
    end
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
    grouped_rows(mods&.map_data) do |entry|
      composed = [entry.scale, entry.projection, entry.coordinates]
                 .compact_blank.join(MAP_DATA_SEPARATOR).presence
      next unless composed

      [entry.display_label.presence || MAP_DATA_LABEL, linked_value(composed, entry.href)]
    end
  end

  def use_and_reproduction
    labeled_field(mods&.use_and_reproduction_display_label.presence || USE_AND_REPRODUCTION_LABEL,
                  mods&.use_and_reproduction, href: mods&.use_and_reproduction_href)
  end

  def restriction_on_access
    labeled_field(mods&.restriction_on_access_display_label.presence || RESTRICTION_ON_ACCESS_LABEL,
                  mods&.restriction_on_access, href: mods&.restriction_on_access_href)
  end

  # The combined accessCondition is the only value carrying an untyped one, so
  # it renders only when neither typed field claimed anything. Otherwise a
  # record with a licence would show the same text twice.
  def access_condition
    return '' if mods&.use_and_reproduction.present? || mods&.restriction_on_access.present?

    labeled_field(mods&.access_condition_display_label.presence || ACCESS_CONDITION_LABEL,
                  mods&.access_condition, href: mods&.access_condition_href)
  end

  private

    # One row per header, in the order the headers first appear. A record that
    # labels one of two values asks for two headers, so values group by the
    # header they carry rather than by the field they came from, which is why
    # no row in this file heads itself.
    #
    # The block answers with [header, value] for one entry, or nil to drop it.
    # A value may be a list, for a row whose entry renders several <dd>s.
    def grouped_rows(entries)
      grouped = Array(entries).each_with_object({}) do |entry, hsh|
        label, value = yield(entry)
        next if label.blank? || value.blank?

        (hsh[label] ||= []).concat(Array.wrap(value))
      end
      safe_join(grouped.map { |label, values| html_field(label, values) })
    end

    # #grouped_rows for a { value:, display_label:, href: } field, which is
    # every plain row.
    def labeled_rows(default_label, entries, capitalize: false, axis: nil)
      grouped_rows(entries) do |entry|
        next if entry.value.blank?

        rendered = capitalize ? entry.value.upcase_first : entry.value
        # The indexed value is the record's own string, never the capitalised
        # one: "Sound recording" is displayed against an indexed "sound
        # recording", which is exactly the drift the marker exists to bridge.
        [header_for(entry, default_label),
         browse_value(rendered, axis, value: entry.value,
                      authority: entry.try(:authority), href: entry.href)]
      end
    end

    # The header a row takes. @displayLabel wins outright -- it is the record
    # saying what it wants this called. An originInfo block's @eventType comes
    # next, because it names the event the block records and no default can.
    # The field's own label is the fallback.
    def header_for(entry, default_label)
      entry.display_label.presence ||
        (entry.respond_to?(:event_type) ? entry.event_type.presence : nil) ||
        default_label
    end

    # Which date element the place's own block carries decides the header.
    def place_header(entry)
      header_for(entry, nil) || place_date_label(entry) || DEFAULT_PLACE_LABEL
    end

    # dateIssued leads, so a block carrying both dates reads as a publication.
    # Driven by the order of PLACE_LABELS rather than by the order the dates
    # arrive in, so the reading does not depend on how the gem sorted them.
    def place_date_label(entry)
      dates = Array(entry.date_elements)
      PLACE_LABELS.find { |element, _| dates.include?(element) }&.last
    end

    # An agent's roleTerm heads its row, which is the whole difference between
    # an agent and a publisher: the record says what the agent did.
    def agent_header(entry)
      header_for(entry, nil) || name_labels(entry).first
    end

    def related_item_header(item)
      item.display_label.presence ||
        RELATED_ITEM_LABELS[NEU::MODS::Projection.fold_type(item.type)] ||
        GENERIC_RELATED_ITEM_LABEL
    end

    def identifier_value(entry)
      rendered = entry.type.present? ? "#{entry.type.upcase}: #{entry.value}" : entry.value
      entry.invalid ? "#{rendered} #{INVALID_IDENTIFIER_MARK}" : rendered
    end

    def qualified_language(entry)
      qualifiers = [entry.object_part, entry.script].compact_blank
      qualifiers.empty? ? entry.term : "#{entry.term} (#{qualifiers.join(', ')})"
    end

    # The digital origin in the words a reader uses, carrying the header and
    # the link of the physicalDescription it came from.
    def digital_origin_entries
      Array(mods&.digital_origin).filter_map do |entry|
        next if entry.value.blank?

        Metadata::Fields::LabeledValue.new(
          value: DIGITAL_ORIGIN_LABELS.fetch(entry.value.downcase, entry.value.upcase_first),
          display_label: entry.display_label, href: entry.href
        )
      end
    end

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

    # The headers one name files under. A record's own @displayLabel replaces
    # the lot: it is the record saying what this name is to be called.
    def name_headers(entry, lead:)
      return [entry.display_label] if entry.display_label.present?

      name_labels(entry, lead: lead)
    end

    # The labels one name files under, from its roles.
    #
    # A name declaring NO role takes the lead label when it leads and the
    # trailing one otherwise. A record listing six unmarked names said that six
    # people were involved, and filing all six under Creator asserted six
    # creators -- a claim the record never made.
    #
    # The unknown-role label is a LAST resort, not a per-role one. A name
    # carrying "aut" and a typo'd "qqq" was filed under both, so a reader saw
    # the same person twice -- the second time under a role the record never
    # asserted. A name with at least one role this system knows is already
    # filed correctly, and the unrecognised code adds nothing but the
    # duplicate.
    def name_labels(entry, lead: true)
      roles = Array(entry.roles).compact_blank
      return [lead ? NO_ROLE_LABEL : TRAILING_NAME_LABEL] if roles.empty?

      known = roles.reject { |role| MarcRelators.unknown_code?(role) }
                   .filter_map { |role| MarcRelators.label(role) }.uniq
      known.presence || [UNKNOWN_ROLE_LABEL]
    end

    # Which role-less names lead. A record that marks one usage="primary" has
    # named its principal name, so that one leads and the first-in-document
    # rule does not apply; a record that marks none falls back to the first,
    # which is the order a cataloguer entered them in.
    def leading_name_indexes(entries)
      roleless = entries.each_index.select { |index| Array(entries[index].roles).compact_blank.empty? }
      primary = roleless.select { |index| entries[index].usage == PRIMARY_USAGE }
      (primary.presence || roleless.first(1)).to_set
    end

    def render_plain_row(row)
      labeled_rows(row[:label], mods&.public_send(row[:field]),
                   capitalize: row.fetch(:capitalize, false), axis: row[:axis])
    end

    # A date renders everything the record declared about it: the value at its
    # own granularity, the other end of a range at the end's own granularity,
    # and the qualifier around the whole thing. "circa 1935-1940" is honest
    # where "1935" and "1935-1940" both are not.
    #
    # A record whose date is not a w3cdtf or ISO 8601 one has no value to
    # format, and the gem hands over the literal instead. Showing "19uu" is
    # what the record says; the alternative is a row a cataloguer filled in
    # that no reader ever sees.
    def mods_date(label, attribute)
      header = part(attribute, 'display_label').presence || part(attribute, 'event_type').presence || label
      # paragraphs: false -- a date is a value, and a <p> around it would give
      # the row a shape every consumer of this block already lays out without.
      return labeled_field(header, part(attribute, 'text'), paragraphs: false) unless dated?(attribute)

      labeled_field(header, composed_date(attribute), paragraphs: false)
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

    def part(attribute, name) = mods&.public_send(:"#{attribute}_#{name}")

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

    # The heading as one string, which neu-mods composes so the display and the
    # browse index cannot separate a heading differently.
    #
    # An access copy stored before neu-mods 0.14.0 carries the parts and no
    # joined form, and a reindex is what repopulates it -- so between a deploy
    # and that reindex the parts are joined here instead. Through the gem's own
    # separator, which is what keeps this from being a second join with a mind
    # of its own.
    def composed_heading(heading)
      heading.heading.presence ||
        Array(heading.parts).compact_blank.join(NEU::MODS::Projection::HEADING_SEPARATOR).presence
    end

    # A name marked with the browse it belongs to. The DISPLAYED string carries
    # the alternative name and the affiliation and the INDEXED one does not, so
    # the marker states the indexed value rather than leaving a consumer to
    # match on what it can see.
    def browse_name(entry)
      browse_value(name_with_qualifiers(entry), MODSBrowse.name_axis(entry),
                   value: entry.name, authority: entry.authority, href: entry.href)
    end

    # "Doe, Jane [Mark Twain, Department of Physics]". One bracket around the
    # alternative name and the affiliation, because both qualify the same name
    # and two brackets side by side read as two separate things. Neither ever
    # becomes a grouping key: two physicists in different departments still
    # belong under one Creator heading.
    def name_with_qualifiers(entry)
      extras = (Array(entry.alternative_names) + Array(entry.affiliation)).compact_blank
      return entry.name if extras.empty?

      "#{entry.name} [#{extras.join(NAME_QUALIFIER_SEPARATOR)}]"
    end
end
