# frozen_string_literal: true

json.community do
  json.id @community.noid
  json.title @community.plain_title
  json.description @community.plain_description
  # TODO: move to mods specific call
  # json.mods @community.mods.json_attributes
end
