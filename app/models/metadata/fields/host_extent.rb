# frozen_string_literal: true

module Metadata
  module Fields
    # A MODS <part><extent> at a unit other than page, which HostCollection's
    # start_page and end_page hold. extent/@unit is an open xs:string and the
    # numbers mean nothing without it -- the minutes of a recording and the
    # columns of a newspaper are both "0" to "45" -- so the unit travels with
    # them.
    class HostExtent
      include AttrJson::Model

      attr_json :unit, :string
      attr_json :start, :string
      attr_json :end, :string
      attr_json :total, :string
      attr_json :list, :string
    end
  end
end
