# frozen_string_literal: true

module Metadata
  module Fields
    # A MODS <relatedItem> that is neither a series nor a host -- otherFormat,
    # original, preceding, reviewOf and the rest. The type rides along because
    # "the print edition" and "reviewed in" are different relationships, and the
    # title alone cannot tell them apart.
    class RelatedItem
      include AttrJson::Model

      attr_json :type, :string
      attr_json :title, :string
    end
  end
end
