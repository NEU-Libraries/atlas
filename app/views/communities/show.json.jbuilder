# frozen_string_literal: true

json.community do
  json.id @community.noid
  json.ancestors @community.ancestors
  json.thumbnail @community.thumbnail
  json.title @community.plain_title
  json.description @community.plain_description
end
