# frozen_string_literal: true

# Admin-only history surface for a resource. Intentionally does NOT load
# the Valkyrie resource — history rows exist for tombstoned or destroyed
# resources too, and that's a load-bearing property: the audit trail must
# survive deletion of what it audits.
class AuditEventsController < ApplicationController
  before_action :verify_admin

  def index
    @events = AuditEvent.for_resource(params[:id]).recent
  end

  private

    def verify_admin
      return if @current_user&.admin?

      render json: { error: 'admin only' }, status: :forbidden
    end
end
