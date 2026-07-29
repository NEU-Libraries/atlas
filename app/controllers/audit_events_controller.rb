# frozen_string_literal: true

# Admin-only history surface for a resource. Intentionally does NOT load the
# Valkyrie resource for rendering — history rows exist for tombstoned or
# destroyed resources too, and the audit trail must survive deletion of what it
# audits. The lookup is keyed on the Valkyrie UUID the writer stores in
# AuditEvent#resource_id, so we resolve the URL's NOID → UUID before scoping,
# falling back to the raw param for already-destroyed resources and legacy
# NOID-literal rows.
# TODO: persist the NOID alongside the UUID at write time so post-destroy
# lookups by NOID work natively, retiring the resolved_resource_id fallback.
class AuditEventsController < ApplicationController
  def index
    authorize! :read, AuditEvent
    @events = AuditEvent.for_resource(resolved_resource_id).recent
  end

  # Session-scoped emit: an AuditEvent with no resource to hang on —
  # impersonation start/end. The session lifecycle lives in the
  # calling app (Cerberus, a cookie); view-as performs no resource writes
  # at all, so there is no mutation to attach the event to. Principals
  # travel in the body (self-describing) rather than inferred from headers,
  # because an `impersonation_ended` emit fires as the session is torn down.
  #
  # Admin-gated: :admin carries `:create AuditEvent` via `manage :all`, and the
  # devolved-admin tier carries it via Ability#apply_admin_delegate_abilities
  # (both impersonation modes call this before establishing a session — Atlas
  # trusts Cerberus's own admin-only gate on acting-as to decide which mode a
  # delegate may reach). Every other principal — :system, :guest, standard
  # humans — is denied 403.
  def create
    authorize! :create, AuditEvent

    # NB: read the body's `action` from request_parameters, not params —
    # `params[:action]` is reserved by the router and resolves to the
    # controller action name ("create"), shadowing the emit's action field.
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

    # `mode` (acting_as / view_as) has no dedicated column — it's a property
    # of the session, not the content graph — so it rides in the jsonb
    # payload alongside any caller-supplied metadata.
    def session_payload(body)
      base = body['payload'].is_a?(Hash) ? body['payload'].dup : {}
      base['mode'] = body['mode'] if body['mode'].present?
      base
    end

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
