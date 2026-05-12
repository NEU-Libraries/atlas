# frozen_string_literal: true

json.file_set do
  json.id file_set.noid
  json.type file_set.type
  json.tombstoned file_set.tombstoned
  json.tombstoned_at file_set.tombstoned_at&.to_s
  json.tombstoned_by file_set.tombstoned_by
end
