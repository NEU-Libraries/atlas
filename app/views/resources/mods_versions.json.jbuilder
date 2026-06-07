# frozen_string_literal: true

# MODS version-history envelope. Mirrors the /history envelope
# ({ resource_id, events }) and reuses the AuditEvent descriptor field names
# so a consumer can render this stream with the same timestamp/actor helpers
# it uses for the audit log, and cross-reference the two. Reverse-chronological.
json.resource_id @resource_id
json.versions do |root|
  root.array!(@versions) do |version|
    json.version_id version[:version_id]
    json.created version[:created]
    json.actor_nuid version[:actor_nuid]
    json.on_behalf_of_nuid version[:on_behalf_of_nuid]
    json.source version[:source]
    json.note version[:note]
  end
end
