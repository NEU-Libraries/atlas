# frozen_string_literal: true

json.file_set do
  json.id @file_set.noid
  json.mets @file_set.mets.json_attributes
end
