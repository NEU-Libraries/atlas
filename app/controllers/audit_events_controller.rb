# frozen_string_literal: true

# Admin-only history surface for a resource. Intentionally does NOT load
# the Valkyrie resource — history rows exist for tombstoned or destroyed
# resources too, and that's a load-bearing property: the audit trail must
# survive deletion of what it audits.
class AuditEventsController < ApplicationController
  def index
    authorize! :read, AuditEvent
    @events = AuditEvent.for_resource(params[:id]).recent
  end
end
