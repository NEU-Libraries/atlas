# frozen_string_literal: true

json.collection do
  json.id @collection.noid
  json.mods @collection.mods.json_attributes
end
