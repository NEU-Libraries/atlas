# frozen_string_literal: true

# Ordered page listing: one entry per page-bearing FileSet, position ASC
# (nulls last, creation-order tie-break), grouping preserved — unlike
# /works/:id/assets, which flattens FileSet membership away.
json.array! @pages do |file_set, assets|
  json.noid file_set.noid
  json.type file_set.type
  json.position file_set.position
  json.tombstoned file_set.tombstoned
  json.assets assets do |asset|
    json.partial! 'works/asset', asset: asset, classification: file_set.type
  end
end
