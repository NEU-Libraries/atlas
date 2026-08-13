# frozen_string_literal: true

json.work do
  json.id @work.noid
  json.valkyrie_id @work.id.to_s
  json.ancestors @work.ancestors
  json.thumbnail @work.thumbnail_uri
  json.thumbnail_2x @work.thumbnail_uri_for(Role.thumbnail_image_2x.name)
  json.preview @work.thumbnail_uri_for(Role.preview_image.name)
  # Per-asset derivative read policy (sparse tier => [read groups]; see
  # TierVisibility). Keys span the image ladder (small/medium/large/service/
  # master) plus independent media (audio/video/pdf). Echoed for Cerberus's
  # editing UI; the effective per-asset gate is surfaced on /works/:id/assets.
  json.derivative_permissions @work.derivative_permissions_map
  json.title @work.plain_title
  json.description @work.plain_description
  json.permanent_url @work.mods&.permanent_url
  json.tombstoned @work.tombstoned
  json.tombstoned_at @work.tombstoned_at&.to_s
  json.tombstoned_by @work.tombstoned_by
  json.depositor @work.depositor
  json.proxy_uploader @work.proxy_uploader
  json.in_progress @work.in_progress
  json.incomplete @work.incomplete
  json.incomplete_reason @work.incomplete_reason
end
