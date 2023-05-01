# frozen_string_literal: true

json.community do
  json.id @community.noid
  json.mods @community.mods.json_attributes
end
