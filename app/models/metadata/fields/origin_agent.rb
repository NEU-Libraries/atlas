# frozen_string_literal: true

module Metadata
  module Fields
    # A MODS 3.8 originInfo/agent: who performed the event the block records.
    # Shaped like a Name because the gem composes it through the same port, with
    # the block's @eventType beside it -- which is what heads the row when the
    # record states no displayLabel. Declared apart from Name rather than
    # inherited: attr_json models carry their attribute set as class state, and
    # a subclass sharing it would put event_type on every name.
    class OriginAgent
      include AttrJson::Model
      include Displayable

      attr_json :name, :string
      attr_json :roles, :string, array: true, default: -> { [] }
      attr_json :affiliation, :string, array: true, default: -> { [] }
      attr_json :usage, :string
      attr_json :alternative_names, :string, array: true, default: -> { [] }
      attr_json :event_type, :string
    end
  end
end
