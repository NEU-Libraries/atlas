# frozen_string_literal: true

module Metadata
  module Fields
    # A MODS <recordInfo>: who catalogued this record, to what standard, and
    # when. It describes the CATALOGUING rather than the resource, which is why
    # it is one value and why it does not belong beside Publisher on a work
    # page -- see WorkDecorator::NOT_DISPLAYED for where that decision sits.
    class RecordInfo
      include AttrJson::Model

      attr_json :content_source, :string
      attr_json :origin, :string
      attr_json :description_standard, :string
      attr_json :creation_date, :string
      attr_json :change_date, :string
      attr_json :language_of_cataloging, :string
    end
  end
end
