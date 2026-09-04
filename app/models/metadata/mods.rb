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

    # Fields whose value is not a plain string. Everything absent from this map
    # is :string, single or array according to its FIELDS cardinality.
    TYPES = {
      main_title:                       Metadata::Fields::TitleInfo.to_type,
      names:                            Metadata::Fields::Name.to_type,
      notes:                            Metadata::Fields::Note.to_type,
      location:                         Metadata::Fields::Location.to_type,
      map_data:                         Metadata::Fields::MapData.to_type,
      related_items:                    Metadata::Fields::RelatedItem.to_type,
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
    }.freeze

    NEU::MODS::FIELDS.each do |field, cardinality|
      attr_json field, TYPES.fetch(field, :string), array: cardinality == :many
    end
  end
end
