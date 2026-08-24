# frozen_string_literal: true

json.file_sets do |root|
  root.array!(@file_sets) do |file_set|
    json.partial! 'file_sets/file_set_fields', file_set: file_set
  end
end
json.pagination @pagination
