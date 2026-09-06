# frozen_string_literal: true

module Metadata
  module Fields
    # One MODS <subject> held as the ordered parts a cataloguer built it from.
    # The per-axis fields pool every topic on a record into one list, so they
    # cannot say which parts belonged to the same heading; this can. The parts
    # stay apart because the separator between them is display policy.
    class SubjectHeading
      include AttrJson::Model

      attr_json :parts, :string, array: true, default: -> { [] }
    end
  end
end
