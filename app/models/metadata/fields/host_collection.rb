# frozen_string_literal: true

module Metadata
  module Fields
    # A MODS <relatedItem type="host"> with this work's position in it. The
    # host's own name, originInfo and identifier are absent on purpose: they
    # belong to the other record and go stale when it is edited. The volume,
    # issue and page range are the exception, because they describe this work
    # and no other record holds them.
    class HostCollection
      include AttrJson::Model

      attr_json :title, :string
      attr_json :volume, :string
      attr_json :issue, :string
      attr_json :start_page, :string
      attr_json :end_page, :string
    end
  end
end
