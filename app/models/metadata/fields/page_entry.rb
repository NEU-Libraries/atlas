# frozen_string_literal: true

module Metadata
  module Fields
    # One page div from a Work-level METS physical structMap: the page
    # FileSet's NOID, its ORDER (null for legacy/unordered pages — array
    # position still reflects document order), and its LABEL
    # (classification name).
    class PageEntry
      include AttrJson::Model

      attr_json :noid, :string
      attr_json :order, :integer
      attr_json :label, :string
    end
  end
end
