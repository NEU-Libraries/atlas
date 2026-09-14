# frozen_string_literal: true

module Metadata
  module Fields
    # The two attributes a display reads off a MODS element rather than out of
    # its text: the header the record asked for (@displayLabel) and the link it
    # attached (xlink:href). MODS puts both on the same 26 elements, so they are
    # declared once here instead of repeated on a dozen models -- the same
    # argument the neu-mods projection makes for reading them as one pair.
    module Displayable
      extend ActiveSupport::Concern

      included do
        attr_json :display_label, :string
        attr_json :href, :string
      end
    end
  end
end
