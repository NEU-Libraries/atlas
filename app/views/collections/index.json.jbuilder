# frozen_string_literal: true

json.collections do |root|
  root.array!(@collections) do |collection|
    json.collection do
      json.id collection.noid
      json.title collection.plain_title
      json.description collection.plain_description
    end
  end
end
json.pagination @pagination
