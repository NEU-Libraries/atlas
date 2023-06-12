# frozen_string_literal: true

json.collection do
  json.id @collection.noid
  json.title @collection.plain_title
  json.description @collection.plain_description
end
