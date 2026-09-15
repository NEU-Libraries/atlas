# frozen_string_literal: true

module Metadata
  # The JSON access copy of a resource's MODS. The preservation copy is the XML
  # blob; this row exists so a read never has to parse it.
  #
  # The attribute set is DERIVED from NEU::MODS::FIELDS rather than restated
  # here. Restating it is what let nineteen attributes sit declared-but-never-
  # projected: nothing failed when the two drifted, the attribute just stayed
  # nil and the display row silently did not render. Deriving makes that drift
  # structurally impossible instead of merely tested.
  #
  # No migration is needed to add a field. attr_json attributes live in the
  # existing json_attributes jsonb column, which mods_json= assigns wholesale.
  class MODS < ApplicationRecord
    include AttrJson::Record

    # Fields that project as { value:, display_label:, href: } -- every plain
    # string field a record can re-head with @displayLabel. Listed rather than
    # mapped one by one so adding a displayed field is one line.
    LABELED_VALUE_FIELDS = %i[
      alternative_title uniform_title translated_title abbreviated_title
      classification table_of_contents resource_type target_audience
      format extent digital_origin reformatting_quality
      physical_description_notes related_series
    ].freeze

    # Labeled fields that ALSO carry the vocabulary their term came from. Genre
    # is the only one: it is a browse axis, and a consumer offering a link needs
    # to know the term is controlled. The rest stay plain -- nothing gates on
    # the vocabulary of an extent, and three more keys on fourteen fields is
    # JSON no consumer reads.
    AUTHORIZED_VALUE_FIELDS = %i[genres].freeze

    # Fields inside an originInfo block, which also carry its @eventType.
    ORIGIN_VALUE_FIELDS = %i[publication_information edition issuance frequency].freeze

    # Fields whose value is not a plain string. Everything absent from this map
    # is :string, single or array according to its FIELDS cardinality.
    TYPES = {
      main_title:                       Metadata::Fields::TitleInfo.to_type,
      place_of_publication:             Metadata::Fields::OriginPlace.to_type,
      origin_agents:                    Metadata::Fields::OriginAgent.to_type,
      names:                            Metadata::Fields::Name.to_type,
      languages:                        Metadata::Fields::Language.to_type,
      notes:                            Metadata::Fields::Note.to_type,
      location:                         Metadata::Fields::Location.to_type,
      map_data:                         Metadata::Fields::MapData.to_type,
      related_items:                    Metadata::Fields::RelatedItem.to_type,
      host_collections:                 Metadata::Fields::HostCollection.to_type,
      subject_headings:                 Metadata::Fields::SubjectHeading.to_type,
      identifiers:                      Metadata::Fields::Identifier.to_type,
      record_info:                      Metadata::Fields::RecordInfo.to_type,
      hierarchical_geographic_subjects: Metadata::Fields::HierarchicalGeographic.to_type,

      # A date projects six fields. The two values are datetimes because the
      # sort key, the citation year and the OAI date all need a real date
      # object; the key-date flag is the record nominating its own principal
      # date, so it is a boolean rather than a string.
      date_created:                     :datetime,
      date_created_end:                 :datetime,
      date_created_key_date:            :boolean,
      date_issued:                      :datetime,
      date_issued_end:                  :datetime,
      date_issued_key_date:             :boolean,
      copyright_date:                   :datetime,
      copyright_date_end:               :datetime,
      copyright_date_key_date:          :boolean
    }.merge(LABELED_VALUE_FIELDS.index_with { Metadata::Fields::LabeledValue.to_type })
            .merge(AUTHORIZED_VALUE_FIELDS.index_with { Metadata::Fields::AuthorizedValue.to_type })
            .merge(ORIGIN_VALUE_FIELDS.index_with { Metadata::Fields::OriginValue.to_type })
            .freeze

    NEU::MODS::FIELDS.each do |field, cardinality|
      attr_json field, TYPES.fetch(field, :string), array: cardinality == :many
    end
  end
end
