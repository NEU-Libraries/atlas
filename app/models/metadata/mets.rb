# frozen_string_literal: true

module Metadata
  class METS < ApplicationRecord
    include AttrJson::Record

    attr_json :created_at_iso, :string
    attr_json :agent, :string
    attr_json :files, Metadata::Fields::FileEntry.to_type, array: true
    attr_json :structure_label, :string
  end
end
