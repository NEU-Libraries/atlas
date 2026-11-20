# frozen_string_literal: true

module Metadata
  module Fields
    # One page div from a Work-level METS physical structMap. ORDER is null
    # for an unordered page, whose array position still gives its order.
    # LABEL is null until FileSets carry a page label.
    class PageEntry
      include AttrJson::Model

      attr_json :noid, :string
      attr_json :order, :integer
      attr_json :label, :string
    end
  end
end
