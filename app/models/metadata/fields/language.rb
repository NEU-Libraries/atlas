# frozen_string_literal: true

module Metadata
  module Fields
    # A MODS <language> as the access copy holds it. The @objectPart rides with
    # the term because it changes the claim: objectPart="subtitles" says the
    # subtitles are Spanish, not the resource, and a captioned video carries
    # exactly that. The script is here for the reason a Name keeps its role --
    # no consumer can recover it from the term.
    class Language
      include AttrJson::Model

      attr_json :term, :string
      attr_json :object_part, :string
      attr_json :script, :string
    end
  end
end
