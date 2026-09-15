# frozen_string_literal: true

module Metadata
  module Fields
    # The three attributes MODS uses to say which vocabulary a value was taken
    # from. A consumer deciding whether to offer a value as a browse link asks
    # for any of the three: MODS lets a record declare its vocabulary by URI
    # alone, and DRS holds corporate names in exactly that shape, so requiring
    # @authority would call them uncontrolled.
    #
    # Separate from Displayable, which is the pair a HEADER comes from. The two
    # resolve differently -- a header often comes from a parent element and an
    # authority never does -- and only four fields carry this one, where every
    # displayed field carries that one.
    module Authorized
      extend ActiveSupport::Concern

      included do
        attr_json :authority, :string
        attr_json :authority_uri, :string
        attr_json :value_uri, :string
      end
    end
  end
end
