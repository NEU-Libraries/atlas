# frozen_string_literal: true

require 'rails_helper'

# The piece-2 auth-matrix regression. Verifies the require_auth rewrite
# (closes both pre-piece-2 footguns: missing User header silently elevating
# to :system, and a mismatched token silently falling through to guest) and
# the per-endpoint :system-principal allowlist on resource-writing actions.
#
# See gap_reports/proxy_uploader_and_system_auth.md and
# gap_reports/plan_atlas.md piece 2 for the design rationale.
RSpec.describe 'Auth matrix', type: :request do
  let(:cerberus_token) { 'test-cerberus-token' }

  before do
    allow(Rails.application.credentials)
      .to receive(:cerberus_token).and_return(cerberus_token)
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

  describe 'per-endpoint reject_system_principal' do
    it 'rejects the :system principal on POST /works' do
      post '/works',
           params:  { collection_id: collection.noid }.to_json,
           headers: auth_headers(nuid: system_user.nuid).merge('Content-Type' => 'application/json')
      expect(response).to have_http_status(:forbidden)
    end

    it 'rejects the :system principal on Work tombstone' do
      work = WorkCreator.call(parent_id: collection.noid)
      post "/works/#{work.noid}/tombstone",
           headers: auth_headers(nuid: system_user.nuid)
      expect(response).to have_http_status(:forbidden)
    end

    it 'permits non-system principals on POST /works' do
      post '/works',
           params:  { collection_id: collection.noid }.to_json,
           headers: auth_headers(nuid: privileged.nuid).merge('Content-Type' => 'application/json')
      expect(response.status).to be_in([200, 201])
    end

    it 'rejects the :system principal on Collection tombstone but permits create (Q7 lean)' do
      # tombstone — rejected
      post "/collections/#{collection.noid}/tombstone",
           headers: auth_headers(nuid: system_user.nuid)
      expect(response).to have_http_status(:forbidden)

      # create — still permitted (the seed task currently depends on this)
      post '/collections',
           params:  { parent_id: community.noid }.to_json,
           headers: auth_headers(nuid: system_user.nuid).merge('Content-Type' => 'application/json')
      expect(response.status).to be_in([200, 201])
    end

    it 'rejects the :system principal on Community tombstone but permits create (Q7 lean)' do
      empty_community = CommunityCreator.call
      post "/communities/#{empty_community.noid}/tombstone",
           headers: auth_headers(nuid: system_user.nuid)
      expect(response).to have_http_status(:forbidden)

      post '/communities',
           params:  {}.to_json,
           headers: auth_headers(nuid: system_user.nuid).merge('Content-Type' => 'application/json')
      expect(response.status).to be_in([200, 201])
    end

    it 'permits the :system principal on PUT /users/by_nuid/:nuid (provisioning stays system-only)' do
      put '/users/by_nuid/001234567',
          params:  { groups: [], email: 'x@y.z', name: 'X' }.to_json,
          headers: auth_headers(nuid: system_user.nuid).merge('Content-Type' => 'application/json')
      expect(response).to have_http_status(:ok)
    end
  end
end
