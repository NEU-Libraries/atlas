# frozen_string_literal: true

json.resource_id params[:id]
json.events do |root|
  root.array!(@events) do |event|
    json.id event.id
    json.actor_nuid event.actor_nuid
    json.on_behalf_of_nuid event.on_behalf_of_nuid
    json.action event.action
    json.change_type event.change_type
    json.event_source event.event_source
    json.occurred_at event.occurred_at.iso8601
    json.resource_type event.resource_type
    json.payload event.payload
    json.note event.note
  end
end
