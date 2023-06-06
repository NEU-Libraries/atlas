# frozen_string_literal: true

json.work do
  json.id @work.noid
  json.mods @work.mods.json_attributes
end
