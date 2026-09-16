# frozen_string_literal: true

module Metadata
  # The JSON access copy of a resource's MODS; the XML blob preserves. See
  # docs/mods.md.
  #
  # The attribute set is DERIVED from NEU::MODS::FIELDS, never restated:
  # restating it let nineteen attributes sit declared-but-never-projected,
  # failing silently. Adding a field needs no migration -- attr_json lives in
  # the existing json_attributes jsonb column.
  class MODS < ApplicationRecord
    include AttrJson::Record

    # Project as { value:, display_label:, href: }: every plain string field a
    # record can re-head with @displayLabel.
    LABELED_VALUE_FIELDS = %i[
      alternative_title uniform_title translated_title abbreviated_title
      classification table_of_contents resource_type target_audience
      format extent digital_origin reformatting_quality
      physical_description_notes related_series
    ].freeze

    # Genre alone also carries its vocabulary: it is a browse axis, and a
    # consumer offering a link needs to know the term is controlled.
    AUTHORIZED_VALUE_FIELDS = %i[genres].freeze

    # Fields inside an originInfo block, which also carry its @eventType.
    ORIGIN_VALUE_FIELDS = %i[publication_information edition issuance frequency].freeze

    # Anything absent is :string, single or array by its FIELDS cardinality.
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

      # Datetimes because the sort key, the citation year and the OAI date all
      # need a real date object; the key-date flag is a boolean because it is
      # the record nominating its own principal date.
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
