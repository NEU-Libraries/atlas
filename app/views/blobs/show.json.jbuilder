# frozen_string_literal: true

json.blob do
  json.id @blob.noid
  json.mime_type @blob.mime_type
  json.original_filename @blob.original_filename
  json.use @blob.use
  json.label Label.find(@blob.label).name if @blob.label
  json.file_identifiers @blob.file_identifiers
end
