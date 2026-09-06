# frozen_string_literal: true

module Metadata
  module Fields
    # A MODS <relatedItem type="host"> with this work's position in it. The
    # host's own name, originInfo and identifier are absent on purpose: they
    # belong to the other record and go stale when it is edited. The part is
    # the exception, because it describes this work and no other record holds
    # it.
    #
    # Volume, issue and the page range are named because they are the citation
    # and a reader asks for them by name. The rest of the part arrives
    # structured, since detail/@type and extent/@unit are open strings.
    class HostCollection
      include AttrJson::Model

      attr_json :title, :string
      attr_json :volume, :string
      attr_json :issue, :string
      attr_json :start_page, :string
      attr_json :end_page, :string

      # The article's year within the host. After the title it is the element a
      # reader most needs to find the article offline.
      attr_json :date, :string
      attr_json :text, :string

      attr_json :details, Metadata::Fields::HostDetail.to_type, array: true, default: -> { [] }
      attr_json :extents, Metadata::Fields::HostExtent.to_type, array: true, default: -> { [] }
    end
  end
end
