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

# The permissions.json a resource's OCFL object holds at its head, or nil.
def on_disk_permissions(resource)
  path = OcflHealth::Pool.new([TestStorage.root]).object_path(resource.noid)
  return nil if path.nil?

  validator = OcflHealth::ObjectValidator.new(path, key: resource.noid, fixity: false).call
  OcflHealth::Envelope.read(validator).permissions
end

# Each resource's last write, to pass back as `since:`.
def envelope_snapshot = Atlas.query.find_all.to_h { |resource| [resource.id.to_s, resource.updated_at] }

# Every resource whose envelope lags Postgres, mapped to what lags. With
# `since:`, only the resources written after that snapshot.
def lagging_envelopes(since: nil)
  pool = OcflHealth::Pool.new([TestStorage.root])
  envelope_candidates(since).each_with_object({}) do |resource, drift|
    lag = envelope_lag(pool, resource) if owes_envelope?(resource)
    drift[resource] = lag if lag
  end
end

# Unless a resource has gone: a graph names its members by NOID, and a purge
# drops a member without saving the resource that names it.
def envelope_candidates(since)
  resources = Atlas.query.find_all.to_a
  return resources if since.nil? || (since.keys - resources.map { |r| r.id.to_s }).any?

  resources.reject { |r| since[r.id.to_s] == r.updated_at }
end

# A Delegate and a Derivative FileSet owe no envelope; every other resource owes
# one, so a missing object counts.
def owes_envelope?(resource)
  return false if resource.is_a?(Delegate)

  !resource.is_a?(FileSet) || Classification.preserved?(resource.type)
end

def envelope_lag(pool, resource)
  path = pool.object_path(resource.noid)
  return 'no envelope' if path.nil?

  envelope = OcflHealth::Envelope.read(OcflHealth::ObjectValidator.new(path, key: resource.noid, fixity: false).call)
  return 'no graph file' if envelope.graph.nil?

  drift = envelope.drift(graph: resource.graph_payload.as_json, permissions: resource.permissions_payload.as_json)
  drift.map { |file, keys| "#{file} (#{keys.join(', ')})" }.join('; ').presence
end
