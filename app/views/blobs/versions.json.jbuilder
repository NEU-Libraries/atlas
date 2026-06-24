# frozen_string_literal: true

# Binary version-history envelope. The counterpart to
# resources/mods_versions.json.jbuilder: a reverse-chronological list of the
# Blob's retained content revisions, each carrying its OCFL version label,
# file identifier, fixity digest, size, and actor attribution correlated from
# the file audit ledger.
json.blob_id @blob.noid
json.versions do |root|
  root.array!(@versions) do |version|
    json.version_id version[:version_id]
    json.file_identifier version[:file_identifier]
    json.created version[:created]
    json.actor_nuid version[:actor_nuid]
    json.on_behalf_of_nuid version[:on_behalf_of_nuid]
    json.digest version[:digest]
    json.size version[:size]
    json.original_filename version[:original_filename]
  end
end
