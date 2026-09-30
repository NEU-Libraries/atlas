# frozen_string_literal: true

# The assets shape for tombstoned FileSets, plus who withdrew each one and
# when. The stamp is the FileSet's, since the FileSet is the withdrawn unit.
json.array! @assets do |asset, file_set|
  json.partial! 'works/asset', asset: asset, file_set: file_set
  json.tombstoned_at file_set.tombstoned_at&.to_s
  json.tombstoned_by file_set.tombstoned_by
end
