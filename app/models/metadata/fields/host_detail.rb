# frozen_string_literal: true

module Metadata
  module Fields
    # A MODS <part><detail> other than the volume and issue HostCollection
    # names directly. detail/@type is an open xs:string, so the type rides
    # along as a value rather than becoming a key -- a fixed key per type
    # cannot cover a vocabulary the schema does not close.
    #
    # The caption is the label a cataloguer wrote for the number ("chap."
    # before "7"), and no consumer can reconstruct it from the type.
    class HostDetail
      include AttrJson::Model

      attr_json :type, :string
      attr_json :number, :string
      attr_json :caption, :string
      attr_json :title, :string
    end
  end
end
