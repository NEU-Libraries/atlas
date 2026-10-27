# frozen_string_literal: true

json.due @due do |row|
  json.key row.key
  json.object "#{Valkyrie::Storage::OCFL::INVENTORY_ID_NAMESPACE}:#{row.key}"
  json.bytes row.bytes
  json.last_checked_at row.last_checked_at&.utc&.iso8601
end
