# frozen_string_literal: true

require 'rails_helper'

# The piece-2 auth-matrix regression, extended in piece 6 with the
# token-pairing rules.
#
# Closes the pre-piece-2 footguns (missing User header silently elevating
# to :system, mismatched token silently falling through to guest); the
# piece-7 Ability layer 403s; and the piece-6 cross-pairing footgun (user
# token impersonating :system, system token impersonating a real person).
#
# See gap_reports/proxy_uploader_and_system_auth.md, gap_reports/
# plan_atlas.md pieces 2 and 6, and the piece-6 prompt for design notes.
#
# default_auth: false — this spec drives the auth matrix by hand, so the
# global admin-default in spec/support/auth_request_helper.rb does not apply.
RSpec.describe 'Auth matrix', type: :request, default_auth: false do
  let(:cerberus_token) { 'test-cerberus-token' }
  let(:system_token)   { 'test-system-token' }

  before do
    allow(Rails.application.credentials)
      .to receive(:cerberus_token).and_return(cerberus_token)
    allow(Rails.application.credentials)
      .to receive(:system_token).and_return(system_token)
  end

  let!(:system_user) do
    User.create!(email: 'system@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000000', name: 'User, System', role: :system)
  end
  let!(:guest) do
    User.create!(email: 'guest@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000001', name: 'User, Guest', role: :guest)
  end
  let!(:anonymous) do
    User.create!(email: 'anon@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000099', name: 'User, Anonymous', role: :anonymous)
  end
  let!(:privileged) do
    User.create!(email: 'priv@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000002', name: 'Doe, Jane', role: :privileged)
  end

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  def auth_headers(token: cerberus_token, nuid: nil)
    h = {}
    h['Authorization'] = "Bearer #{token}" unless token.nil?
    h['User']          = "NUID #{nuid}"    if nuid
    h
  end

  describe 'require_auth resolution' do
    it 'resolves a known principal when token + User header are valid' do
      get '/communities', headers: auth_headers(nuid: privileged.nuid)
      expect(response).to have_http_status(:ok)
    end

    it 'returns 400 when the User header is missing under a valid token' do
      get '/communities', headers: auth_headers
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['error']).to match(/User: NUID header required/)
    end

    it 'returns 400 when the User header names an unknown NUID' do
      get '/communities', headers: auth_headers(nuid: '999999999')
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['error']).to match(/unknown principal/)
    end

    it 'returns 401 when the User header points at the :anonymous fixture' do
      get '/communities', headers: auth_headers(nuid: anonymous.nuid)
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['error']).to match(/anonymous cannot authenticate/)
    end

    it 'returns 401 for a mismatched (non-JWT) bearer token' do
      get '/communities', headers: auth_headers(token: 'definitely-not-the-token',
                                                nuid:  privileged.nuid)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'falls through to guest when no Authorization header is sent' do
      get '/communities', headers: auth_headers(token: nil)
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'piece-6 token-pairing matrix' do
    it 'rejects cerberus_token paired with the :system NUID (401)' do
      get '/communities', headers: auth_headers(token: cerberus_token, nuid: system_user.nuid)
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['error']).to match(/user token must not be paired with the :system fixture/)
    end

    it 'rejects system_token paired with a real-person NUID (401)' do
      get '/communities', headers: auth_headers(token: system_token, nuid: privileged.nuid)
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['error']).to match(/system token must only be paired with the :system fixture/)
    end

    it 'resolves :system when system_token is paired with the :system NUID' do
      put '/users/by_nuid/001234567',
          params:  { groups: [], email: 'x@y.z', name: 'X' }.to_json,
          headers: auth_headers(token: system_token, nuid: system_user.nuid).merge('Content-Type' => 'application/json')
      expect(response).to have_http_status(:ok)
    end

    it 'returns 400 when system_token is sent without a User header' do
      get '/communities', headers: auth_headers(token: system_token)
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['error']).to match(/User: NUID header required/)
    end

    it 'returns 400 when system_token is paired with an unknown NUID' do
      get '/communities', headers: auth_headers(token: system_token, nuid: '999999999')
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['error']).to match(/unknown principal/)
    end
  end

  describe 'Ability-driven 403s on write actions (system_token-paired)' do
    # Post-piece-6, the :system principal authenticates with system_token,
    # not cerberus_token. The Ability layer still denies :system on Work
    # creation / mutation; only the wire token used to reach the action
    # changes.
    def system_headers
      auth_headers(token: system_token, nuid: system_user.nuid)
    end

    it 'rejects the :system principal on POST /works' do
      post '/works',
           params:  { collection_id: collection.noid }.to_json,
           headers: system_headers.merge('Content-Type' => 'application/json')
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to include('action' => 'create', 'subject' => 'Work')
    end

    it 'rejects the :system principal on Work tombstone' do
      work = WorkCreator.call(parent_id: collection.noid)
      post "/works/#{work.noid}/tombstone", headers: system_headers
      expect(response).to have_http_status(:forbidden)
    end

    it 'permits non-system principals on POST /works' do
      post '/works',
           params:  { collection_id: collection.noid }.to_json,
           headers: auth_headers(nuid: privileged.nuid).merge('Content-Type' => 'application/json')
      expect(response.status).to be_in([200, 201])
    end

    it 'rejects the :system principal on Collection tombstone but permits create (Q7 lean)' do
      post "/collections/#{collection.noid}/tombstone", headers: system_headers
      expect(response).to have_http_status(:forbidden)

      post '/collections',
           params:  { parent_id: community.noid }.to_json,
           headers: system_headers.merge('Content-Type' => 'application/json')
      expect(response.status).to be_in([200, 201])
    end

    it 'rejects the :system principal on Community tombstone but permits create (Q7 lean)' do
      empty_community = CommunityCreator.call
      post "/communities/#{empty_community.noid}/tombstone", headers: system_headers
      expect(response).to have_http_status(:forbidden)

      post '/communities',
           params:  {}.to_json,
           headers: system_headers.merge('Content-Type' => 'application/json')
      expect(response.status).to be_in([200, 201])
    end

    it 'permits the :system principal on PUT /users/by_nuid/:nuid (provisioning stays system-only)' do
      put '/users/by_nuid/001234567',
          params:  { groups: [], email: 'x@y.z', name: 'X' }.to_json,
          headers: system_headers.merge('Content-Type' => 'application/json')
      expect(response).to have_http_status(:ok)
    end
  end
end
