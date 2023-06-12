# frozen_string_literal: true

json.file_sets do |root|
  root.array!(@file_sets) do |file_set|
    json.file_set do
      json.id file_set.noid
    end
  end
end
json.pagination @pagination
