# frozen_string_literal: true

class MODSIndexer
  # Projected MODS field => the Solr field it lands in. This mirrors
  # WorkDecorator::DISPLAY: one declarative row per indexed field, so a field
  # cannot be projected, stored, displayed and then silently absent from
  # discovery. That is exactly what happened to `languages` -- extracted,
  # rendered, and zero values in Solr across every document, so a language
  # facet was impossible rather than merely unconfigured.
  #
  # The names follow what Cerberus's Blacklight config already declares, so
  # repointing a facet is a config change there rather than a rename here.
  SOLR_FIELDS = {
    # The four variant titles share one match-only field. They must not join
    # title_tsim: that is the heading a result row renders, so adding a variant
    # to it would change what a reader sees rather than what they can find.
    alternative_title:       :title_variant_tesim,
    uniform_title:           :title_variant_tesim,
    translated_title:        :title_variant_tesim,
    abbreviated_title:       :title_variant_tesim,
    languages:               :language_ssim,
    resource_type:           :resource_type_ssim,
    topical_subjects:        :subject_ssim,
    geographic_subjects:     :subject_geo_ssim,
    temporal_subjects:       :subject_era_ssim,
    personal_name_subjects:  :subject_person_ssim,
    corporate_name_subjects: :subject_corporate_ssim,
    publication_information: :publisher_ssim,
    related_series:          :series_ssim,
    host_collections:        :host_collection_ssim,
    # Searchable, not facetable: faceting on an identifier would make one
    # bucket per record. Being *searched* also needs the field in the request
    # handler's qf, which the blacklight-solr image owns -- indexing it here is
    # necessary and not sufficient.
    identifiers:             :identifier_tesim
  }.freeze

  # Projected fields this indexer does not write, and why. Kept as a map rather
  # than a list so "another indexer owns it" is distinguishable from "no
  # discovery value" -- the two are different decisions, and only the second is
  # one to revisit.
  NOT_INDEXED = {
    main_title:               'title_tsim / title_plain_tsim here, title_ssi in SortIndexer',
    names:                    'creator_ssim in CitationIndexer, creator_ssi in SortIndexer',
    abstract:                 'description_tsim here',
    genres:                   'genre_ssim in GenreIndexer',
    permanent_url:            'permanent_url_ssi here',
    date_created:             'date_ssi in SortIndexer, pub_date_ssim in CitationIndexer',
    date_issued:              'SortIndexer::DATE_FIELDS falls back through it into date_ssi',
    copyright_date:           'SortIndexer::DATE_FIELDS falls back through it into date_ssi',
    date_created_precision:   'chooses a display format; not a value a reader searches',
    date_issued_precision:    'chooses a display format; not a value a reader searches',
    copyright_date_precision: 'chooses a display format; not a value a reader searches',
    edition:                  'display only',
    format:                   'display only',
    extent:                   'display only',
    digital_origin:           'display only',
    notes:                    'display only; free text already reachable through full_text_tesimv',
    map_data:                 'display only; coordinates need a spatial field, not a string one',
    related_items:            'display only; the relationship types have no browse',
    location:                 'display only; a shelf mark is not a search term',
    access_condition:         'rights text is not a search term',
    use_and_reproduction:     'rights text is not a search term',
    restriction_on_access:    'rights text is not a search term'
  }.freeze

  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    fields = {}

    # Operational flags get projected unconditionally so /works?in_progress
    # can find stuck deposits even before MODS metadata is filled in.
    fields[:in_progress_bsi] = resource.in_progress if resource.respond_to?(:in_progress)

    # The pipeline-failure pair (Work#incomplete). Both go to Solr because a
    # consumer renders the "Incomplete" pill and its cause straight from the
    # search document — an unindexed field cannot drive it, and a per-row
    # fetch to read one flag would defeat the result list.
    if resource.respond_to?(:incomplete)
      fields[:incomplete_bsi]        = resource.incomplete
      fields[:incomplete_reason_ssi] = resource.incomplete_reason
    end

    if decorated_resource.try(:plain_title)
      fields[:title_tsim] = decorated_resource.plain_title
      fields[:description_tsim] = decorated_resource.plain_description
      fields[:permanent_url_ssi] = decorated_resource.mods&.permanent_url
      add_match_title(fields, decorated_resource.plain_title)
      add_descriptive_fields(fields)
    end

    fields
  end

  def decorated_resource
    @decorated_resource ||= resource.decorate
  end

  private

    # One Solr field per SOLR_FIELDS row. A field is written only when it has a
    # value, so a sparse record does not carry empty facet entries; it appears
    # the next time the resource is saved or reindexed, the same lifecycle
    # genre_ssim has.
    def add_descriptive_fields(fields)
      mods = decorated_resource.mods
      return if mods.nil?

      SOLR_FIELDS.each do |field, solr_field|
        values = Array(mods.public_send(field)).compact_blank
        next if values.empty?

        # Accumulated, not assigned: several projected fields can share one
        # Solr field, as the four variant titles do.
        fields[solr_field] = (fields.fetch(solr_field, []) + values).uniq
      end
    end

    # title_tsim is both the match field and the display field a result row
    # renders, so it keeps the record's <sub>/<sup> markup -- which makes Solr
    # tokenise "sub" as a term of its own and leaves "Bi2Sr2CaCu2O8", the
    # formula a reader types, matching nothing. title_plain_tsim is the
    # match-only twin: the same title with the markup removed. Stripping
    # title_tsim instead would fix matching and break every result heading.
    #
    # Written only when the two differ, so an ordinary title is not indexed
    # twice. Being searched needs the field in the request handler's qf, which
    # the blacklight-solr image owns, as it does for full_text_tesimv.
    def add_match_title(fields, title)
      plain = EnhancedText.strip(title)
      fields[:title_plain_tsim] = plain unless plain == title
    end
end
