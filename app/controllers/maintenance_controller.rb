# frozen_string_literal: true

class MaintenanceController < ApplicationController
  # Reset runs unauthenticated on purpose -- RESETTABLE_ENVS is the only gate.
  # Auth here would break a bootstrap chicken-and-egg: the action re-seeds the
  # fixture users, so the first call against a fresh container has nobody to
  # authenticate as. skip_authorization_check stops check_authorization
  # tripping on an action that never calls authorize!.
  skip_before_action :require_auth, only: :reset
  skip_authorization_check only: :reset

  # On the read floor deliberately: refused during maintenance, Cerberus could
  # never see the flag it is meant to be honouring.
  def show
    authorize! :read, :maintenance

    @maintenance = MaintenanceMode.current
    render 'maintenance/show'
  end

  # The one action that stays reachable while the window is OPEN (see
  # #read_only_exempt?), or the window could never be closed.
  def update
    authorize! :maintain, :maintenance

    read_only = ActiveModel::Type::Boolean.new.cast(params[:read_only])
    return render_error(:bad_request, 'read_only is required') if read_only.nil?

    # An unnamed door is a human; the deploy orchestrator names itself.
    source = params[:source].presence || 'operator'
    return render_error(:bad_request, "unknown source #{source}") unless MaintenanceMode::SOURCES.include?(source)

    @maintenance = if read_only
                     MaintenanceMode.open!(source: source, message: params[:message].presence,
                                           retry_after: params[:retry_after].presence&.to_i)
                   else
                     MaintenanceMode.close!(source: source)
                   end
    audit_maintenance_event
    render 'maintenance/show'
  end

  # RepositoryReset holds the env guard and the maintenance check itself, so
  # `rake reset:clean` reaches the same wipe without this route.
  def reset
    RepositoryReset.call
  end

  private

    # The SOLE exemption from the maintenance floor. Without it an open window
    # would refuse the very request that closes it.
    def read_only_exempt?
      action_name == 'update'
    end

    # :system-gated, so without this the ledger would record the system
    # principal flipping the flag and not who asked. Mirrors
    # Users::TokensController#audit_token_event.
    def audit_maintenance_event
      AuditEventWriter.record(
        actor_nuid:        @current_user.nuid,
        on_behalf_of_nuid: @on_behalf_of,
        action:            @maintenance.read_only? ? 'open_maintenance_window' : 'close_maintenance_window',
        change_type:       'maintenance',
        event_source:      'controller',
        payload:           { source: @maintenance.source, message: @maintenance.message }.compact
      )
    end
end
