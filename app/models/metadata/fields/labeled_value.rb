# frozen_string_literal: true

module Metadata
  module Fields
    # A displayed MODS value and the header its element asked for. The shape
    # every plain string field takes once a record can override its header: a
    # bare string cannot carry the label, and a parallel array of labels could
    # be zipped to the wrong value.
    class LabeledValue
      include AttrJson::Model
      include Displayable

      attr_json :value, :string
    end
  end
end
