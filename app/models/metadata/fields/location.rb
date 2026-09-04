# frozen_string_literal: true

module Metadata
  module Fields
    # A MODS <location>. The parts stay apart because a shelf mark and a URL are
    # not interchangeable: the display has to know which it holds before it can
    # decide to linkify it.
    class Location
      include AttrJson::Model

      attr_json :physical_location, :string
      attr_json :shelf_location, :string
      attr_json :url, :string
    end
  end
end
