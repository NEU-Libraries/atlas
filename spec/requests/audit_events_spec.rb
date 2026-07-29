# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Audit history endpoint', type: :request do
  let!(:admin) do
    User.find_by(nuid: '000000004') ||
      User.create!(email: 'admin@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000004', name: 'User, Admin', role: :admin)
  end
  let!(:guest) do
    User.find_by(role: :guest) ||
      User.create!(email: 'guest@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000001', name: 'User, Guest', role: :guest)
  end

  let(:resource_id) { 'qrfj8zz' }

  let!(:older) do
    AuditEvent.create!(
      resource_id:   resource_id,
      resource_type: 'Work',
      actor_nuid:    '000000002',
      action:        'create',
      change_type:   'structural',
      event_source:  'controller',
      occurred_at:   2.days.ago
    )
  end
  let!(:newer) do
    AuditEvent.create!(
      resource_id:   resource_id,
      resource_type: 'Work',
      actor_nuid:    '000000002',
      action:        'update',
      change_type:   'metadata',
      event_source:  'controller',
      occurred_at:   1.day.ago
    )
  end

  let(:admin_headers) { signed_auth_headers(admin.nuid) }
  let(:guest_headers) { signed_auth_headers(guest.nuid) }

  describe 'GET /resources/:id/history' do
    it 'returns 200 with reverse-chronological events for an admin' do
      get "/resources/#{resource_id}/history", headers: admin_headers
      expect(response).to have_http_status(:ok)

      payload = response.parsed_body
      expect(payload['resource_id']).to eq(resource_id)
      # parsed_body returns a plain Array, not an AR scope; Rails/Pluck doesn't apply.
      expect(payload['events'].map { |e| e['action'] }).to eq(%w[update create]) # rubocop:disable Rails/Pluck
    end

    it 'rejects non-admin callers with 403' do
      get "/resources/#{resource_id}/history", headers: guest_headers
      expect(response).to have_http_status(:forbidden)
    end

    it 'resolves the URL NOID to the Valkyrie UUID the writer stored' do
      # Regression coverage: the writer persists resource_id as the
      # Valkyrie UUID (resource&.id&.to_s), but callers hit this
      # endpoint with the NOID. Without NOID-to-UUID resolution in the
      # controller, the lookup misses every event written via the real
      # AuditEventWriter path.
      community = CommunityCreator.call
      collection = CollectionCreator.call(parent_id: community.noid)
      work = WorkCreator.call(
        parent_id:  collection.noid,
        actor_nuid: '000000004'
      )
      # Sanity: writer stamped resource_id with the UUID, not the NOID.
      stamped = AuditEvent.where(actor_nuid: '000000004', action: 'create').last
      expect(stamped.resource_id).to eq(work.id.to_s)
      expect(stamped.resource_id).not_to eq(work.noid)

      # And the endpoint, called with the NOID, still finds the row.
      get "/resources/#{work.noid}/history", headers: admin_headers
      expect(response).to have_http_status(:ok)
      actions = response.parsed_body['events'].map { |e| e['action'] } # rubocop:disable Rails/Pluck
      expect(actions).to include('create')
    end

    it 'returns rows for resources that no longer exist (lifecycle-decoupled)' do
      # Even though resource_id "missing999" has no corresponding Valkyrie row,
      # any AuditEvents stamped with it remain queryable.
      AuditEvent.create!(
        resource_id:   'missing999',
        resource_type: 'Work',
        actor_nuid:    '000000004',
        action:        'tombstone',
        change_type:   'lifecycle',
        event_source:  'controller'
      )

      get '/resources/missing999/history', headers: admin_headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['events'].length).to eq(1)
    end

    it 'returns an empty array for a resource with no events' do
      get '/resources/no-events-xyz/history', headers: admin_headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['events']).to eq([])
    end
  end

  # Session-scoped emit: impersonation start/end events that hang on
  # no resource. atlas_rb's AtlasRb::AuditEvent.emit drives this endpoint.
  describe 'POST /audit_events' do
    let(:json_headers) { admin_headers.merge('Content-Type' => 'application/json') }

    let(:emit_body) do
      { action:            'impersonation_started',
        actor_nuid:        admin.nuid,
        on_behalf_of_nuid: '900000001',
        mode:              'acting_as' }
    end

    it 'records a session-scoped event (null resource) and returns it for an admin' do
      expect do
        post '/audit_events', params: emit_body.to_json, headers: json_headers
      end.to change(AuditEvent, :count).by(1)

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body).to include(
        'action'            => 'impersonation_started',
        'actor_nuid'        => admin.nuid,
        'on_behalf_of_nuid' => '900000001',
        'change_type'       => 'session',
        'event_source'      => 'controller',
        'resource_id'       => nil,
        'resource_type'     => nil
      )
      # mode has no column — it rides in the jsonb payload.
      expect(body['payload']).to include('mode' => 'acting_as')

      event = AuditEvent.last
      expect(event.resource_id).to be_nil
      expect(event.session_event?).to be(true)
    end

    it 'records an impersonation_ended event' do
      post '/audit_events',
           params:  emit_body.merge(action: 'impersonation_ended', mode: 'view_as').to_json,
           headers: json_headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body['action']).to eq('impersonation_ended')
      expect(response.parsed_body['payload']).to include('mode' => 'view_as')
    end

    it 'rejects a non-admin caller with 403' do
      expect do
        post '/audit_events',
             params:  emit_body.to_json,
             headers: guest_headers.merge('Content-Type' => 'application/json')
      end.not_to change(AuditEvent, :count)
      expect(response).to have_http_status(:forbidden)
    end

    # Devolved-admin tier: :privileged role + Permissions::ADMIN_GROUP, jointly.
    # Unblocks Cerberus's impersonation session-start audit write for both
    # view-as and acting-as modes — Atlas trusts Cerberus's own admin-only
    # gate on acting-as to decide which mode a delegate may actually reach.
    describe 'devolved-admin tier' do
      let!(:delegate) do
        User.create!(email: 'delegate-audit@example.invalid', password: SecureRandom.hex(16),
                     nuid: '000000042', name: 'Williams, Delegate', role: :privileged,
                     groups: [Permissions::ADMIN_GROUP])
      end
      let!(:staff_no_group) do
        User.create!(email: 'staff-no-group-audit@example.invalid', password: SecureRandom.hex(16),
                     nuid: '000000043', name: 'Roe, Sam', role: :privileged,
                     groups: [Permissions::STAFF_EDIT_GROUP])
      end
      let(:delegate_headers) { signed_auth_headers(delegate.nuid).merge('Content-Type' => 'application/json') }

      it 'permits the delegate to emit a view_as session-start event' do
        expect do
          post '/audit_events', params: emit_body.merge(mode: 'view_as').to_json, headers: delegate_headers
        end.to change(AuditEvent, :count).by(1)
        expect(response).to have_http_status(:created)
      end

      it 'denies :privileged-without-the-group with 403' do
        headers = signed_auth_headers(staff_no_group.nuid).merge('Content-Type' => 'application/json')
        expect do
          post '/audit_events', params: emit_body.to_json, headers: headers
        end.not_to change(AuditEvent, :count)
        expect(response).to have_http_status(:forbidden)
      end

      it 'does not broaden the generic audit-history index (:create != :read AuditEvent)' do
        get "/resources/#{resource_id}/history", headers: signed_auth_headers(delegate.nuid)
        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
