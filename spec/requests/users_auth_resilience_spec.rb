# frozen_string_literal: true

require 'rails_helper'

# Regression coverage for system-bearer auth when no User row exists for
# the :system role (e.g. an environment whose DB was never seeded with the
# system user). The controllers gating on `current_user.system?` previously
# raised NoMethodError; they must now answer 403.
RSpec.describe 'System-bearer auth resilience', type: :request do
  let(:system_token) { 'test-system-token' }

  before do
    allow(Rails.application.credentials)
      .to receive(:cerberus_token).and_return(system_token)
    allow(User).to receive(:find_by_role).with(:system).and_return(nil)
    # Guest fallback path is not exercised here, but stub it too so the
    # spec doesn't depend on suite seed state.
    allow(User).to receive(:find_by_role).with(:guest).and_return(nil)
  end

  it 'PUT /users/by_nuid/:nuid returns 403 instead of raising' do
    put '/users/by_nuid/001234567',
        params: { groups: [], email: 'x@y.z', name: 'X' }.to_json,
        headers: { 'Authorization' => "Bearer #{system_token}",
                   'Content-Type' => 'application/json' }
    expect(response).to have_http_status(:forbidden)
  end

  it 'POST /nuid returns 403 instead of raising' do
    post '/nuid',
         params: { nuid: '001234567' }.to_json,
         headers: { 'Authorization' => "Bearer #{system_token}",
                    'Content-Type' => 'application/json' }
    expect(response).to have_http_status(:forbidden)
  end
end
