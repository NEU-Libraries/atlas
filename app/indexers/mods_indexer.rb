# frozen_string_literal: true

class MODSIndexer
  # One declarative row per indexed field, mirroring WorkDecorator::DISPLAY, so
  # a field cannot be projected, stored, displayed and then silently absent
  # from discovery. The names are Cerberus's Blacklight config, so repointing a
  # facet is a config change there rather than a rename here.
  SOLR_FIELDS = {
    # The four variant titles share one match-only field. They must not join
    # title_tsim: that is the heading a result row renders, so adding a variant
    # to it would change what a reader sees rather than what they can find.
    alternative_title:                :title_variant_tesim,
    uniform_title:                    :title_variant_tesim,
    translated_title:                 :title_variant_tesim,
    abbreviated_title:                :title_variant_tesim,
    languages:                        :language_ssim,
    place_of_publication:             :place_ssim,

    # The one subject axis NOT indexed through AXIS_FIELDS below: a reader
    # browsing Places wants the narrowest level, and the heading composes a
    # whole path. Some records use this axis INSTEAD of subject/geographic.
    hierarchical_geographic_subjects: :subject_geo_ssim,

    # NOT classification_ssim -- that field carries the FileSet content-type
    # vocabulary and drives Cerberus's shipped Content facet, so mixing the two
    # corrupts a working facet. DRS writes IPTC photo categories here.
    classification:                   :photo_category_ssim,

    # Its own field rather than folded into description_tsim. A chapter list is
    # long and keyword-dense, so sharing the abstract's field would let it
    # outrank real abstracts in relevance scoring.
    table_of_contents:                :contents_tesim,

    resource_type:                    :resource_type_ssim,
    publication_information:          :publisher_ssim,
    related_series:                   :series_ssim,
    host_collections:                 :host_collection_ssim,
    # Searchable, not facetable. Being searched also needs the field in the
    # request handler's qf, which the blacklight-solr image owns.
    identifiers:                      :identifier_tesim
  }.freeze

  # For fields whose members are models: the attribute carrying the indexable
  # text, so a DOI reaches Solr as digits and not as an inspect output. See
  # docs/solr-indexing.md for why each one facets on the part it does.
  #
  # The labeled rows are DERIVED from the access copy's own declaration rather
  # than restated, so a field that gains a header cannot start indexing a
  # model's inspect output.
  LABELED_MEMBER_VALUES =
    (Metadata::MODS::LABELED_VALUE_FIELDS + Metadata::MODS::AUTHORIZED_VALUE_FIELDS +
      Metadata::MODS::ORIGIN_VALUE_FIELDS)
    .index_with { :value }.freeze

  SOLR_MEMBER_VALUES = {
    identifiers: :value, host_collections: :title, languages: :term,
    place_of_publication: :value
  }.merge(LABELED_MEMBER_VALUES).freeze

  # Fields whose members need composing rather than reading: the private method
  # that turns one entry into the string Solr should hold.
  SOLR_MEMBER_COMPOSERS = { hierarchical_geographic_subjects: :narrowest_place }.freeze

  # Fields choosing their Solr field PER VALUE. A third bucket beside
  # SOLR_FIELDS and NOT_INDEXED so the coverage guard can tell "indexed
  # differently" from "deliberately not indexed".
  #
  # Emits a LIST per field and never a scalar: a heading is indexed whole
  # today, and the agreed exit is to index the heading AND its parts.
  #
  # ORDERING TRAP: the axis comes off the STORED access copy, so
  # `rake atlas:mods:reproject` must run BEFORE a reindex when the gem's
  # projection is newer than the rows. A reindex over rows that name no axis
  # empties every subject facet rather than moving it.
  AXIS_FIELDS = { subject_headings: MODSBrowse::SUBJECT_AXES }.freeze

  # Derived onto each date below rather than written out: a date added to the
  # gem would otherwise need six more rows or the coverage guard fails on
  # fields nobody meant to index. Headers and event types are not here --
  # COMPANIONS_NOT_INDEXED covers every field's, dates included.
  DATE_PART_REASONS = {
    'precision'     => 'chooses a display format; not a value a reader searches',
    'end'           => 'the far end of a range; a range sorts and facets on its start',
    'end_precision' => 'chooses a display format; not a value a reader searches',
    'qualifier'     => 'renders into the date string; not a value a reader searches',
    'key_date'      => 'chooses which date SortIndexer sorts on; not a facet',
    'text'          => 'the literal of a date that is not w3cdtf; a display value, and unsortable'
  }.freeze

  # Every date the gem projects, found by its key-date flag.
  DATE_PARTS_NOT_INDEXED = NEU::MODS::FIELDS.keys.grep(/_key_date\z/).each_with_object({}) do |flag, hsh|
    prefix = flag.to_s.delete_suffix('_key_date')
    DATE_PART_REASONS.each { |part, reason| hsh[:"#{prefix}_#{part}"] = reason }
  end.freeze

  # Derived so a field that gains a companion cannot go unlisted and fail the
  # coverage guard. None is indexed: faceting on a display value buckets
  # records by their cataloguer's wording, not by what they are about.
  COMPANION_SUFFIXES = /_(display_label|href|event_type)\z/

  COMPANION_REASON = 'a header or a link a record asked for; not a term a reader searches'

  COMPANIONS_NOT_INDEXED =
    NEU::MODS::FIELDS.keys.grep(COMPANION_SUFFIXES).index_with { COMPANION_REASON }.freeze

  # A map rather than a list so "another indexer owns it" is distinguishable
  # from "no discovery value". Only the second is a decision to revisit.
  NOT_INDEXED = {
    main_title:                 'title_tsim / title_plain_tsim here, title_ssi in SortIndexer',
    names:                      'creator_ssim + contributor_ssim in CitationIndexer, creator_ssi in SortIndexer',
    abstract:                   'description_tsim here',
    genres:                     'genre_ssim in GenreIndexer',
    permanent_url:              'permanent_url_ssi here',
    date_created:               'date_ssi in SortIndexer, pub_date_ssim in CitationIndexer',
    date_issued:                'SortIndexer::DATE_FIELDS falls back through it into date_ssi',
    copyright_date:             'SortIndexer::DATE_FIELDS falls back through it into date_ssi',
    issuance:                   'a closed MODS vocabulary of six values; display only',
    frequency:                  'serials only; no browse until the repository holds serials',
    reformatting_quality:       'preservation metadata, not a term a reader searches',
    geographic_code_subjects:   'a MARC GAC code is not a term a reader types; the place name is faceted already',
    record_info:                'cataloguing provenance; on nearly every record, so it has no discriminating power',
    date_captured:              'the digitisation date; provenance, not a term a reader searches',
    date_valid:                 'no browse asked for; display only if a row is ever added',
    date_other:                 'means whatever the cataloguer meant, so it buckets nothing',
    date_modified:              'cataloguing provenance, like record_info',
    edition:                    'display only',
    format:                     'display only',
    extent:                     'display only',
    digital_origin:             'display only',
    notes:                      'display only; free text already reachable through full_text_tesimv',
    map_data:                   'display only; coordinates need a spatial field, not a string one',
    related_items:              'display only; the relationship types have no browse',
    location:                   'display only; a shelf mark is not a search term',
    access_condition:           'rights text is not a search term',
    use_and_reproduction:       'rights text is not a search term',
    restriction_on_access:      'rights text is not a search term',
    topical_subjects:           'a part of a heading, which subject_headings indexes whole through AXIS_FIELDS',
    geographic_subjects:        'a part of a heading, which subject_headings indexes whole through AXIS_FIELDS',
    temporal_subjects:          'a part of a heading, which subject_headings indexes whole through AXIS_FIELDS',
    personal_name_subjects:     'a part of a heading, which subject_headings indexes whole through AXIS_FIELDS',
    corporate_name_subjects:    'a part of a heading, which subject_headings indexes whole through AXIS_FIELDS',
    genre_subjects:             'a part of a heading, which subject_headings indexes whole through AXIS_FIELDS',
    title_subjects:             'a part of a heading, which subject_headings indexes whole through AXIS_FIELDS',
    occupation_subjects:        'no browse asked for; the term reaches search through full_text_tesimv',
    physical_description_notes: 'preservation detail, not a term a reader searches',
    target_audience:            'display only; the audience is a curatorial note, not a browse',
    origin_agents:              'display only; a creator reaches search through CitationIndexer'
  }.merge(DATE_PARTS_NOT_INDEXED).merge(COMPANIONS_NOT_INDEXED).freeze

  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    fields = {}

    # Operational flags get projected unconditionally so /works?in_progress
    # can find stuck deposits even before MODS metadata is filled in.
    fields[:in_progress_bsi] = resource.in_progress if resource.respond_to?(:in_progress)

    # Both reach Solr because a consumer renders the "Incomplete" pill and its
    # cause straight from the search document; a per-row fetch to read one flag
    # would defeat the result list.
    if resource.respond_to?(:incomplete)
      fields[:incomplete_bsi]        = resource.incomplete
      fields[:incomplete_reason_ssi] = resource.incomplete_reason
    end

    add_mods_fields(fields) if decorated_resource.try(:plain_title)

    fields
  end

  def decorated_resource
    @decorated_resource ||= resource.decorate
  end

  private

    def add_mods_fields(fields)
      fields[:title_tsim] = decorated_resource.plain_title
      fields[:description_tsim] = decorated_resource.plain_description
      fields[:permanent_url_ssi] = decorated_resource.mods&.permanent_url
      add_match_title(fields, decorated_resource.plain_title)
      add_descriptive_fields(fields)
    end

    # One field's indexable strings. A member may be a model rather than a
    # string, in which case it is either read (an identifier's value) or
    # composed (a hierarchical place's narrowest level).
    def solr_values(mods, field)
      values = Array(mods.public_send(field))
      member = SOLR_MEMBER_VALUES[field]
      composer = SOLR_MEMBER_COMPOSERS[field]
      values = values.map { |value| value.public_send(member) } if member
      values = values.map { |value| send(composer, value) } if composer
      values.compact_blank
    end

    # Broader levels are implied by the narrow one, so indexing all of them
    # buries the useful value under a continent every record shares.
    def narrowest_place(entry)
      WorkDecorator::PLACE_LEVELS.reverse.filter_map { |level| entry.public_send(level).presence }.first
    end

    # Written only when the field has a value, so a sparse record carries no
    # empty facet entries.
    def add_descriptive_fields(fields)
      mods = decorated_resource.mods
      return if mods.nil?

      SOLR_FIELDS.each do |field, solr_field|
        add_values(fields, solr_field, solr_values(mods, field))
      end
      add_axis_fields(fields, mods)
    end

    # An AXIS_FIELDS row: one Solr field per VALUE, chosen by the axis the
    # value reports. A heading whose axis has no browse field is skipped --
    # subject/occupation is displayed and searchable and buckets nothing.
    def add_axis_fields(fields, mods)
      AXIS_FIELDS.each do |field, axes|
        Array(mods.public_send(field)).each do |entry|
          axis = axes[entry.axis]
          next if axis&.solr.nil?

          add_values(fields, axis.solr, [entry.heading].compact_blank)
        end
      end
    end

    # Accumulated, not assigned: several projected fields can share one Solr
    # field, as the four variant titles and the two place axes do.
    def add_values(fields, solr_field, values)
      return if values.empty?

      fields[solr_field] = (fields.fetch(solr_field, []) + values).uniq
    end

    # The match-only twin of title_tsim, which keeps the record's <sub>/<sup>
    # markup because it is also the display field -- and that markup leaves
    # "Bi2Sr2CaCu2O8" matching nothing. Stripping title_tsim instead would fix
    # matching and break every result heading. Written only when the two
    # differ.
    def add_match_title(fields, title)
      plain = EnhancedText.strip(title)
      fields[:title_plain_tsim] = plain unless plain == title
    end
end
