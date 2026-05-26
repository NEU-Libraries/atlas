# frozen_string_literal: true

# Admin-only history surface for a resource. Intentionally does NOT load
# the Valkyrie resource for rendering — history rows exist for tombstoned
# or destroyed resources too, and that's a load-bearing property: the
# audit trail must survive deletion of what it audits.
#
# But the *lookup* is keyed on AuditEvent#resource_id, which the writer
# stores as the Valkyrie UUID (resource&.id&.to_s). Callers reach this
# endpoint with the NOID in the URL (`/resources/:noid/history`), so we
# resolve NOID → UUID before scoping. If the resource is already
# destroyed (resolve_id raises), fall back to the raw param so older
# rows with NOID-literal resource_ids still match. The deeper fix —
# persist the NOID alongside the UUID at write time so post-destroy
# lookups by NOID work natively — is tracked as a follow-up.
class AuditEventsController < ApplicationController
  def index
    authorize! :read, AuditEvent
    @events = AuditEvent.for_resource(resolved_resource_id).recent
  end

  private

    # Resolve incoming NOID → canonical resource_id (Valkyrie UUID) the
    # writer stores. If the resource is missing — destroyed, never
    # existed, or a legacy row whose resource_id was the NOID itself —
    # fall back to the raw param so older / test-fixture-shaped rows
    # still match. `Resource.find` returns nil on miss (not raises), so
    # safe-nav + .presence is the right shape; no exception handler
    # needed.
    def resolved_resource_id
      Resource.find(params[:id])&.id&.to_s.presence || params[:id]
    end
end
