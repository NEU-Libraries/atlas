# frozen_string_literal: true

json.community do
  json.id @community.noid
  json.valkyrie_id @community.id.to_s
  json.ancestors @community.ancestors
  json.thumbnail @community.thumbnail_uri
  json.thumbnail_2x @community.thumbnail_uri_for(Role.thumbnail_image_2x.name)
  json.preview @community.thumbnail_uri_for(Role.preview_image.name)
  json.title @community.plain_title
  json.description @community.plain_description
  json.permanent_url @community.mods&.permanent_url
  json.tombstoned @community.tombstoned
  json.tombstoned_at @community.tombstoned_at&.to_s
  json.tombstoned_by @community.tombstoned_by
  json.depositor @community.depositor
  json.proxy_uploader @community.proxy_uploader
  json.system_container @community.system_container
end
