# frozen_string_literal: true

# The per-resource history surface, for admins and delegated admins. The
# lookup does not need the Valkyrie resource: the audit trail must survive
# deletion of what it audits. See docs/write-safety.md.
# TODO: persist the NOID alongside the UUID at write time, retiring the
# resolved_resource_id fallback.
class AuditEventsController < ApplicationController
  def index
    resource = Resource.find(params.expect(:id))
    authorize_history!(resource)
    @events = AuditEvent.for_resource(resolved_resource_id(resource)).recent
  end

  # An AuditEvent with no resource to hang on: impersonation start and end.
  # Principals travel in the BODY rather than headers, because an
  # impersonation_ended emit fires as the session is torn down.
  def create
    authorize! :create, AuditEvent

    # NOT params: params[:action] is reserved by the router and resolves to
    # the controller action name, shadowing the emit's own action field.
    body = request.request_parameters
    @event = AuditEventWriter.record(
      actor_nuid:        body['actor_nuid'],
      on_behalf_of_nuid: body['on_behalf_of_nuid'],
      action:            body['action'],
      change_type:       'session',
      event_source:      'controller',
      payload:           session_payload(body)
    )
    render :show, status: :created
  end

  private

    # `mode` has no dedicated column: it is a property of the session, not
    # the content graph.
    def session_payload(body)
      base = body['payload'].is_a?(Hash) ? body['payload'].dup : {}
      base['mode'] = body['mode'] if body['mode'].present?
      base
    end

    # A resource that no longer resolves has no class to grant on, so only
    # :manage reaches its history. The rows carry the before/after access
    # lists, so they must not open what the resource's own read gate shuts.
    def authorize_history!(resource)
      authorize! :read_history, resource&.class || AuditEvent
      authorize! :read, resource if resource
    end

    # Falls back to the raw param for a destroyed resource or a legacy row
    # whose resource_id was the NOID itself.
    def resolved_resource_id(resource)
      resource&.id&.to_s.presence || params[:id]
    end
end
