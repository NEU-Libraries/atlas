# frozen_string_literal: true

# Zeitwerk does not autoload lib/, and the constant below reads OcflHealth at
# load time, so an eager-loading boot fails without this.
require_relative '../../lib/ocfl_health'

# The logical paths in a Blob's OCFL head whose content none of the Blob's
# listed versions holds: what a write leaves when its Blob save loses a lock
# race. Digests come from the inventory, so no bytes are read. See
# docs/binaries.md.
module UnlistedContent
  ENVELOPE_FILES = (OcflHealth::Envelope::GRAPH_FILES + [OcflHealth::Envelope::PERMISSIONS_FILE]).freeze

  def self.paths(blob, validator, adapter: Valkyrie.config.storage_adapter)
    facts  = adapter.find_version_metadata_for(ids: blob.file_identifiers)
    listed = facts.values.to_set { |fact| fact[:digest] }
    (validator.head_logical_paths - ENVELOPE_FILES).reject { |path| listed.include?(validator.head_digest(path)) }
  end
end
