# frozen_string_literal: true

module Metadata
  module Fields
    # A MODS <subject><hierarchicalGeographic>. Kept structured for the reason
    # MapData is: flattening the levels into one string would make a consumer
    # that wants the city alone unpick a sentence.
    #
    # All eleven levels the MODS 3.5 schema allows. Records rarely carry more
    # than three, but the absent ones cost nothing in a jsonb column.
    class HierarchicalGeographic
      include AttrJson::Model

      attr_json :continent, :string
      attr_json :country, :string
      attr_json :province, :string
      attr_json :region, :string
      attr_json :state, :string
      attr_json :territory, :string
      attr_json :county, :string
      attr_json :city, :string
      attr_json :city_section, :string
      attr_json :island, :string
      attr_json :area, :string
    end
  end
end
