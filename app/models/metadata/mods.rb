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
      main_title:     Metadata::Fields::TitleInfo.to_type,
      names:          Metadata::Fields::Name.to_type,
      notes:          Metadata::Fields::Note.to_type,
      location:       Metadata::Fields::Location.to_type,
      map_data:       Metadata::Fields::MapData.to_type,
      related_items:  Metadata::Fields::RelatedItem.to_type,
      date_created:   :datetime,
      date_issued:    :datetime,
      copyright_date: :datetime
    }.freeze

    NEU::MODS::FIELDS.each do |field, cardinality|
      attr_json field, TYPES.fetch(field, :string), array: cardinality == :many
    end
  end
end
