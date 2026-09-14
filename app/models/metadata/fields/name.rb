# frozen_string_literal: true

module Metadata
  module Fields
    # A MODS <name> as the access copy holds it. The affiliation sits on the
    # entry rather than in a parallel field, so a name and its affiliation
    # cannot be zipped together wrongly; it repeats in the schema, so it is an
    # array. So does the role: one person can both write and edit a work, and
    # keeping only the first told a reader half of what the record says.
    class Name
      include AttrJson::Model
      include Displayable

      attr_json :name, :string
      attr_json :roles, :string, array: true, default: -> { [] }
      attr_json :affiliation, :string, array: true, default: -> { [] }

      # @usage is fixed="primary" in the schema and nominates the principal
      # name, which is how a display decides which role-less name leads.
      # alternativeName (MODS 3.7) is a second FORM of this name, not a second
      # name, so it rides on the entry rather than becoming one.
      attr_json :usage, :string
      attr_json :alternative_names, :string, array: true, default: -> { [] }
    end
  end
end
