# frozen_string_literal: true

# Single entry point for emitting AuditEvent rows. Callers pass the
# resource (or nil for session events), the actor's NUID, and the action
# shape; the writer fills in occurred_at and writes a row.
#
# Does not inherit from ApplicationService — that's a Creator base with
# Modsable / NOID helpers that AuditEvent doesn't need.
class AuditEventWriter
  # rubocop:disable Metrics/ParameterLists
  # Every kwarg corresponds to a real AuditEvent column; the wide signature
  # is the public contract of "what makes up an audit row" and is preferable
  # to a generic options hash that hides the shape.
  def self.record(actor_nuid:, action:, change_type:, event_source:,
                  resource: nil, on_behalf_of_nuid: nil,
                  payload: {}, note: nil, occurred_at: Time.current)
    # rubocop:enable Metrics/ParameterLists
    AuditEvent.create!(
      resource_id:       resource&.id&.to_s,
      resource_type:     resource&.class&.name,
      actor_nuid:        actor_nuid,
      on_behalf_of_nuid: on_behalf_of_nuid,
      action:            action,
      change_type:       change_type,
      event_source:      event_source,
      occurred_at:       occurred_at,
      payload:           payload,
      note:              note
    )
  end
end
