# frozen_string_literal: true

json.blobs do |root|
  root.array!(@blobs) do |blob|
    json.id blob.noid
    json.use blob.use
  end
end
json.pagination @pagination
