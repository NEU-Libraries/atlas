# frozen_string_literal: true

module Metadata
  module Fields
    class FileEntry
      include AttrJson::Model

      attr_json :id, :string
      attr_json :mime_type, :string
      attr_json :use, :string
    end
  end
end
