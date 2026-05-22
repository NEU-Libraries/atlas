# frozen_string_literal: true

# Append-only provenance log decoupled from the Valkyrie lifecycle.
# Records who acted on what, when, where, and why — including admin
# impersonation sessions whose effects outlive the resources they touched.
# See gap_reports/proxy_uploader_and_system_auth.md "AuditEvent".
class CreateAuditEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :audit_events do |t|
      t.string   :actor_nuid,        null: false
      t.string   :on_behalf_of_nuid

      t.string   :action,            null: false
      t.string   :change_type,       null: false

      t.datetime :occurred_at,       null: false

      t.string   :event_source,      null: false

      t.jsonb    :payload,           default: {}, null: false
      t.text     :note

      # Raw string ID — no FK constraint; resource may be a Valkyrie row
      # (no AR PK) or already tombstoned/deleted. Nullable for session events
      # (impersonation_started / _ended aren't about a particular resource).
      t.string   :resource_id
      t.string   :resource_type

      t.timestamps
    end

    add_index :audit_events, :actor_nuid
    add_index :audit_events, :on_behalf_of_nuid
    add_index :audit_events, :occurred_at
    add_index :audit_events, %i[resource_id occurred_at], order: { occurred_at: :desc }
    add_index :audit_events, %i[resource_id resource_type]
  end
end
