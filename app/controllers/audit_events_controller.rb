# frozen_string_literal: true

# Admin-only history surface. Deliberately does NOT load the Valkyrie
# resource: the audit trail must survive deletion of what it audits. See
# docs/write-safety.md.
# TODO: persist the NOID alongside the UUID at write time, retiring the
# resolved_resource_id fallback.
class AuditEventsController < ApplicationController
  def index
    authorize! :read, AuditEvent
    @events = AuditEvent.for_resource(resolved_resource_id).recent
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

    # Falls back to the raw param for a destroyed resource or a legacy row
    # whose resource_id was the NOID itself. Resource.find returns nil on a
    # miss rather than raising, so safe-nav is the right shape here.
    def resolved_resource_id
      noid = params.expect(:id)
      Resource.find(noid)&.id&.to_s.presence || noid
    end
end
