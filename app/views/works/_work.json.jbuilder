# frozen_string_literal: true

json.work do
  json.id @work.noid
  json.valkyrie_id @work.id.to_s
  json.ancestors @work.ancestors
  json.thumbnail @work.thumbnail
  json.title @work.plain_title
  json.description @work.plain_description
  json.permanent_url @work.mods&.permanent_url
  json.tombstoned @work.tombstoned
  json.tombstoned_at @work.tombstoned_at&.to_s
  json.tombstoned_by @work.tombstoned_by
  json.in_progress @work.in_progress
end
