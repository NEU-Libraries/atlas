# frozen_string_literal: true

# One Blob's version history; the shape lives in the shared _versions partial
# (see find_many_versions.json.jbuilder for the batched sibling).
json.partial! 'blobs/versions', blob_id: @blob.noid, versions: @versions
