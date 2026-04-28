# frozen_string_literal: true

json.blobs do |root|
  root.array!(@blobs) do |blob|
    json.blob do
      json.id blob.noid
      json.use blob.use
    end
  end
end
json.pagination @pagination
