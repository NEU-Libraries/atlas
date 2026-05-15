# frozen_string_literal: true

# Polymorphic: each element is shaped after its underlying model.
# Blob entries match the legacy /works/:id/files shape (held binary
# with size + filename); Delegate entries describe a pointer-only
# asset (URI + use). Clients pattern-match per element.
json.array! @assets do |asset|
  case asset
  when Blob
    json.extract! asset, :noid, :mime_type, :original_filename, :size
    json.label Label.find(asset.label)&.name
  when Delegate
    json.extract! asset, :noid, :mime_type, :use, :uri
    json.label Label.find(asset.label)&.name
  end
end
