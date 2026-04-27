# frozen_string_literal: true

json.work do
  json.id @work.noid
  json.valkyrie_id @work.id.to_s
  json.ancestors @work.ancestors
  json.thumbnail @work.thumbnail
  json.title @work.plain_title
  json.description @work.plain_description
end
