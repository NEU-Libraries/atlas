# frozen_string_literal: true

# The general-audience sibling of blobs/_versions: one entry per replaced Blob,
# carrying only each revision's ordinal and date. Attribution, digest, size and
# filename stay off, because this read answers to the Work's read gate.
json.array! @revisions do |blob, revisions|
  json.blob_id blob.noid
  json.revisions revisions do |revision|
    json.revision revision[:revision]
    json.created revision[:created]
  end
end
