# frozen_string_literal: true

require 'rails_helper'

# Behavioural coverage for the repository-wide read-only window. The rswag doc
# spec (spec/requests/maintenance_spec.rb) covers the two endpoints' shapes;
# these assert the floor those endpoints control, which the docs can't.
#
# The floor lives in ApplicationController#authorize! rather than Rack
# middleware because a Rack layer keyed on path and method cannot serve reads
# while refusing writes on the same routes.
RSpec.describe 'Maintenance read-only mode', type: :request do
  let(:provision_body) { { nuid: '000000077', name: 'Reader, Casual', groups: [] } }

  after { MaintenanceMode::Cache.reset }

  def open_window!(source: 'operator', message: nil)
    MaintenanceMode.open!(source: source, message: message)
    MaintenanceMode::Cache.reset
  end

  describe 'while the window is closed' do
    it 'serves writes normally' do
      put '/users/by_email/casual@northeastern.edu', params: provision_body, as: :json
      expect(response).to have_http_status(:ok)
    end

    it 'reports the closed window' do
      get '/maintenance'
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body)
        .to include('read_only' => false, 'source' => nil, 'since' => nil)
    end
  end

  describe 'while the window is open' do
    before { open_window!(message: 'Scheduled maintenance until 10:00') }

    it 'refuses a write with a 503 carrying the read_only_mode discriminator' do
      put '/users/by_email/casual@northeastern.edu', params: provision_body, as: :json

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body['error']).to eq('read_only_mode')
      expect(response.headers['Retry-After']).to eq(MaintenanceMode.retry_after.to_s)
    end

    it 'keeps serving reads' do
      get '/users'
      expect(response).to have_http_status(:ok)
    end

    # A refused write must not read as a rights problem: atlas_rb maps 403 to
    # ForbiddenError, which Cerberus renders as a permission-denied page.
    it 'does not refuse the write as a 403' do
      put '/users/by_email/casual@northeastern.edu', params: provision_body, as: :json
      expect(response).not_to have_http_status(:forbidden)
    end

    it 'still answers GET /maintenance, so a client can see the flag it honours' do
      get '/maintenance'

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body)
        .to include('read_only' => true, 'source' => 'operator',
                    'message' => 'Scheduled maintenance until 10:00')
    end

    it 'refuses GET /reset, whose own env guard is a separate concern' do
      get '/reset'
      expect(response).to have_http_status(:service_unavailable)
    end

    it 'stays closable' do
      put '/maintenance', params: { read_only: false }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['read_only']).to be(false)
      expect(MaintenanceMode.first.read_only).to be(false)
    end
  end

  describe 'the source rule between the three doors' do
    it 'refuses to let a finishing deploy close an operator-opened window' do
      open_window!(source: 'operator')

      put '/maintenance', params: { read_only: false, source: 'deploy' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['read_only']).to be(true)
      expect(MaintenanceMode.first.read_only).to be(true)
    end

    it 'lets an operator close a deploy-opened window, because a human is deciding' do
      open_window!(source: 'deploy')

      put '/maintenance', params: { read_only: false, source: 'operator' }, as: :json

      expect(response.parsed_body['read_only']).to be(false)
    end

    it 'rejects an unknown source' do
      put '/maintenance', params: { read_only: true, source: 'cron' }, as: :json
      expect(response).to have_http_status(:bad_request)
    end

    it 'requires read_only rather than defaulting it' do
      put '/maintenance', params: { source: 'operator' }, as: :json
      expect(response).to have_http_status(:bad_request)
    end
  end

  # PUT /maintenance is system-gated, so without the audit the ledger would
  # record the system principal flipping the flag and not who decided.
  describe 'attribution' do
    it 'audits the flip against the acting NUID' do
      expect { put '/maintenance', params: { read_only: true }, as: :json }
        .to change(AuditEvent, :count).by(1)

      event = AuditEvent.last
      expect(event.action).to eq('open_maintenance_window')
      expect(event.change_type).to eq('maintenance')
      expect(event.actor_nuid).to eq(DefaultAuthHeaders::ADMIN_NUID)
      expect(event.payload['source']).to eq('operator')
    end
  end

  describe 'authorization on the flip' do
    it 'refuses a non-admin, non-system caller' do
      User.find_by(nuid: '000000005') ||
        User.create!(email: 'standard@northeastern.edu', password: SecureRandom.hex(16),
                     nuid: '000000005', name: 'User, Standard', role: :standard)

      put '/maintenance', params: { read_only: true }, as: :json,
                          headers: signed_auth_headers('000000005')

      expect(response).to have_http_status(:forbidden)
      expect(MaintenanceMode.first&.read_only).to be_falsey
    end
  end
end
