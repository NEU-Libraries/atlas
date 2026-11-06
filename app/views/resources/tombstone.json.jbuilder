# frozen_string_literal: true

json.set! @root do
  json.id @resource.noid
  json.title @resource.plain_title
  json.permanent_url @resource.mods&.permanent_url
  json.tombstoned true
  json.tombstoned_at @resource.tombstoned_at&.to_s
  json.tombstone_reason @resource.tombstone_reason
end
