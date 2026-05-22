# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Audit history endpoint', type: :request do
  let(:cerberus_token) { 'test-cerberus-token' }

  before do
    allow(Rails.application.credentials)
      .to receive(:cerberus_token).and_return(cerberus_token)
  end

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

  let(:admin_headers) do
    { 'Authorization' => "Bearer #{cerberus_token}",
      'User'          => "NUID #{admin.nuid}" }
  end
  let(:guest_headers) do
    { 'Authorization' => "Bearer #{cerberus_token}",
      'User'          => "NUID #{guest.nuid}" }
  end

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
end
