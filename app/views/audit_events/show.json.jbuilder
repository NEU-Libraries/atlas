# frozen_string_literal: true

# The created AuditEvent envelope returned by POST /audit_events. Shape
# mirrors a single element of the index view's `events` array (plus
# resource_id, which is null for session-scoped events). atlas_rb's
# AtlasRb::AuditEvent.emit parses this into a Mash.
json.id @event.id
json.actor_nuid @event.actor_nuid
json.on_behalf_of_nuid @event.on_behalf_of_nuid
json.action @event.action
json.change_type @event.change_type
json.event_source @event.event_source
json.occurred_at @event.occurred_at.iso8601
json.resource_id @event.resource_id
json.resource_type @event.resource_type
json.payload @event.payload
json.note @event.note
