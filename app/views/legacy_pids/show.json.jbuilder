# frozen_string_literal: true

json.resource do
  json.id @resource.noid
  json.type @resource.class.name
  json.tombstoned @resource.tombstoned
end
