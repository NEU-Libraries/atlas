# frozen_string_literal: true

module Metadata
  module Fields
    # A place of publication, plus the names of the date elements its own
    # originInfo block carries. "Creation place" and "Publication place" are the
    # same element under a different date, and the place says nothing about the
    # event -- so the dates beside it travel with it.
    class OriginPlace
      include AttrJson::Model
      include Displayable

      attr_json :value, :string
      attr_json :event_type, :string
      attr_json :date_elements, :string, array: true, default: -> { [] }
    end
  end
end
