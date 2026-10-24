# frozen_string_literal: true

require Rails.root.join('lib/ocfl_health').to_s

# The relationships.json (or properties.json) a resource's OCFL object holds at
# its head, or nil when it has none. graph_payload is computed from Postgres,
# so a spec that asserts on it says nothing about what reached disk.
def on_disk_envelope(resource)
  path = OcflHealth::Pool.new([TestStorage.root]).object_path(resource.noid)
  return nil if path.nil?

  validator = OcflHealth::ObjectValidator.new(path, key: resource.noid, fixity: false).call
  OcflHealth::Envelope.read(validator).graph
end
