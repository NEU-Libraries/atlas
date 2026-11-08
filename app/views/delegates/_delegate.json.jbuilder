# frozen_string_literal: true

json.delegate do
  json.id @delegate.noid
  json.valkyrie_id @delegate.id.to_s
  json.use @delegate.use
  json.uri(@embargo_withheld && TierVisibility::TIER_FOR_ROLE.key?(@delegate.use) ? nil : @delegate.uri)
  json.mime_type @delegate.mime_type
  json.original_filename @delegate.original_filename
  json.label Label.find(@delegate.label)&.name
  json.tombstoned @delegate.tombstoned
  json.tombstoned_at @delegate.tombstoned_at&.to_s
  json.tombstoned_by @delegate.tombstoned_by
end
