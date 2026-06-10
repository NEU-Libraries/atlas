# frozen_string_literal: true

# Flattened downloadable-assets array; per-element shape lives in the
# shared _asset partial (see works/file_sets.json.jbuilder for the
# grouped sibling).
json.array! @assets do |asset|
  json.partial! 'works/asset', asset: asset
end
