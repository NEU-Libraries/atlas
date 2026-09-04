# frozen_string_literal: true

module Metadata
  module Fields
    # A MODS <note> with its @type. The type is what separates a statement of
    # responsibility from a funding note, so it is stored rather than flattened
    # away -- an untyped note keeps a nil type.
    class Note
      include AttrJson::Model

      attr_json :type, :string
      attr_json :value, :string
    end
  end
end
