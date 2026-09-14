# frozen_string_literal: true

module Metadata
  module Fields
    # A value from inside an originInfo block, carrying that block's @eventType
    # as well as its @displayLabel. MODS puts neither attribute on the
    # publisher, edition, issuance or frequency itself, and @eventType heads the
    # block when no displayLabel does.
    class OriginValue
      include AttrJson::Model
      include Displayable

      attr_json :value, :string
      attr_json :event_type, :string
    end
  end
end
