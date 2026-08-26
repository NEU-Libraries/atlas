# frozen_string_literal: true

# One version-history envelope per resolved Blob, in the order the ids
# resolved. Unordered as far as callers are concerned, and possibly shorter
# than the requested id list — unresolvable ids and non-Blob ids are dropped —
# so consumers index by blob_id. Per-envelope shape lives in the shared
# _versions partial.
json.array!(@histories.to_a) do |blob_id, versions|
  json.partial! 'blobs/versions', blob_id: blob_id, versions: versions
end
