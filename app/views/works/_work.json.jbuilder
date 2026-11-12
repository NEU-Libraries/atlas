# frozen_string_literal: true

json.work do
  json.id @work.noid
  json.valkyrie_id @work.id.to_s
  json.ancestors @work.ancestors
  json.thumbnail @work.thumbnail_uri
  json.thumbnail_2x @work.thumbnail_uri_for(Role.thumbnail_image_2x.name)
  json.partial! 'shared/preview', resource: @work
  # Per-asset derivative read policy (sparse tier => [read groups]; see
  # TierVisibility). Keys span the image ladder (small/medium/large/service/
  # original) plus the independent tiers (INDEPENDENT_MEDIA). Echoed for Cerberus's
  # editing UI; the effective per-asset gate is surfaced on /works/:id/assets.
  json.derivative_permissions GuestRedaction.tier_map(@current_user, @work.derivative_permissions_map)
  json.title @work.plain_title
  json.description @work.plain_description
  json.permanent_url @work.mods&.permanent_url
  json.handle @work.handle
  json.legacy_pid @work.legacy_pid
  json.tombstoned @work.tombstoned
  json.tombstoned_at @work.tombstoned_at&.to_s
  json.updated_at @work.updated_at&.utc&.iso8601
  json.tombstoned_by @work.tombstoned_by
  json.tombstone_reason @work.tombstone_reason
  json.depositor GuestRedaction.nuid(@current_user, @work.depositor)
  json.proxy_uploader GuestRedaction.nuid(@current_user, @work.proxy_uploader)
  json.in_progress @work.in_progress
  json.incomplete @work.incomplete
  json.incomplete_reason @work.incomplete_reason
  json.embargoed @work.embargoed?
  # The setter stores "no embargo" as '', so presence first, as #permissions does.
  json.embargo_release_date @work.embargo_release_date.presence&.to_s
  # The additional records the Work holds, so a caller need not probe each
  # one's endpoint. MODS and METS are never listed: every Work has them.
  json.metadata_formats @work.metadata_formats
end
