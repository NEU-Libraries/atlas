# frozen_string_literal: true

# Polymorphic: each element is shaped after its underlying model.
# Blob entries describe a held binary (size + filename); Delegate
# entries describe a pointer-only asset (URI + use). Clients
# pattern-match per element. Shared by assets.json (flattened) and
# file_sets.json (grouped per page) so the two shapes can't drift.
case asset
when Blob
  json.extract! asset, :noid, :mime_type, :original_filename, :size
  json.label Label.find(asset.label)&.name
when Delegate
  json.extract! asset, :noid, :mime_type, :use, :uri
  json.label Label.find(asset.label)&.name
end
