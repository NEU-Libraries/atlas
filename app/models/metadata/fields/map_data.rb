# frozen_string_literal: true

module Metadata
  module Fields
    # A MODS <subject><cartographics>. Kept structured so a caller wanting only
    # the coordinates does not have to unpick a composed sentence to get them.
    class MapData
      include AttrJson::Model

      attr_json :scale, :string
      attr_json :projection, :string
      attr_json :coordinates, :string
    end
  end
end
