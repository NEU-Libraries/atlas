# frozen_string_literal: true

module Metadata
  module Fields
    # A MODS <name> as the access copy holds it. The affiliation sits on the
    # entry rather than in a parallel field, so a name and its affiliation
    # cannot be zipped together wrongly; it repeats in the schema, so it is an
    # array.
    class Name
      include AttrJson::Model

      attr_json :name, :string
      attr_json :role, :string
      attr_json :affiliation, :string, array: true, default: -> { [] }
    end
  end
end
