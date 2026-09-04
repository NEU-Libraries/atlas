# frozen_string_literal: true

module Metadata
  module Fields
    # A MODS <identifier> with its @type. A DOI, a local accession number and a
    # collection id are not the same kind of thing, and no consumer can tell
    # them apart from the digits alone -- the same reason Note keeps its type.
    class Identifier
      include AttrJson::Model

      attr_json :type, :string
      attr_json :value, :string
    end
  end
end
