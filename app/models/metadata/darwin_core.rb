# frozen_string_literal: true

module Metadata
  # The JSON access copy of a Work's Darwin Core record; the XML Blob
  # preserves. One row per Work, keyed by its NOID in `valkyrie_id`.
  #
  # `json_attributes` is a plain term => value hash rather than attr_json
  # fields: the term list is open, and DarwinCoreDocument owns its shape.
  class DarwinCore < ApplicationRecord
    self.table_name = 'metadata_darwin_core'
  end
end
