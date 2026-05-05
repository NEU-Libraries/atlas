# frozen_string_literal: true

json.community do
  json.id @community.noid
  json.valkyrie_id @community.id.to_s
  json.ancestors @community.ancestors
  json.thumbnail @community.thumbnail
  json.title @community.plain_title
  json.description @community.plain_description
  json.permanent_url @community.mods&.permanent_url
end
