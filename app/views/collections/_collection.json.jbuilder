# frozen_string_literal: true

json.collection do
  json.id @collection.noid
  json.valkyrie_id @collection.id.to_s
  json.ancestors @collection.ancestors
  json.thumbnail @collection.thumbnail_uri
  json.thumbnail_2x @collection.thumbnail_uri_for(Role.thumbnail_image_2x.name)
  json.preview @collection.thumbnail_uri_for(Role.preview_image.name)
  json.title @collection.plain_title
  json.description @collection.plain_description
  json.permanent_url @collection.mods&.permanent_url
  json.tombstoned @collection.tombstoned
  json.tombstoned_at @collection.tombstoned_at&.to_s
  json.tombstoned_by @collection.tombstoned_by
end
