# frozen_string_literal: true

json.blob do
  json.id @blob.noid
  json.mime_type @blob.mime_type
  json.original_filename @blob.original_filename
  json.use @blob.use
  json.size @blob.size
  json.filename @blob.filename
  json.label Label.find(@blob.label)&.name
  json.file_identifiers @blob.file_identifiers
end
