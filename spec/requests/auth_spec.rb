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

  describe 'JWT-direct path (standalone-API access)' do
    include ActiveSupport::Testing::TimeHelpers

    # A devise-jwt minted for a real person authenticates directly, no
    # cerberus_token and no User header — identity lives in the token. Mint with
    # the same encoder POST /nuid uses.
    def mint(user)
      Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)[0]
    end

    def bearer(token, nuid: nil)
      h = { 'Authorization' => "Bearer #{token}" }
      h['User'] = "NUID #{nuid}" if nuid
      h
    end

    it 'resolves the encoded real person from a valid JWT' do
      get '/user', headers: bearer(mint(privileged))
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['nuid']).to eq(privileged.nuid)
    end

    it 'takes identity from the token and ignores the User header' do
      # Token is privileged's; User header names the :system fixture. The header
      # is ignored on the JWT path, so this resolves privileged (not :system,
      # and not the 401 the cross-pairing rule would give the header).
      get '/user', headers: bearer(mint(privileged), nuid: system_user.nuid)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['nuid']).to eq(privileged.nuid)
    end

    it 'rejects an expired JWT (401)' do
      expired = nil
      travel_to(10.days.ago) { expired = mint(privileged) } # 1-week TTL → expired now
      get '/communities', headers: bearer(expired)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a revoked JWT after the jti is rotated (401)' do
      token = mint(privileged)
      User.revoke_jwt(nil, privileged) # rotates jti → outstanding tokens die
      get '/communities', headers: bearer(token)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a JWT encoding the :system bookend (401)' do
      get '/communities', headers: bearer(mint(system_user))
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a JWT encoding the :anonymous bookend (401)' do
      get '/communities', headers: bearer(mint(anonymous))
      expect(response).to have_http_status(:unauthorized)
    end

    it 'forbids On-Behalf-Of on the JWT path even for an admin (403)' do
      admin = User.create!(email: 'admin-jwt@example.invalid', password: SecureRandom.hex(16),
                           nuid: '000000005', name: 'User, Admin', role: :admin)
      get '/communities',
          headers: bearer(mint(admin)).merge('On-Behalf-Of' => 'NUID 900000001')
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body['error']).to match(/On-Behalf-Of requires an admin operator/)
    end
  end

  describe 'Cerberus signed-assertion path (relay replacement, dual-run)' do
    let(:signing_key) { OpenSSL::PKey::EC.generate('prime256v1') }
    let(:kid)         { 'cerberus-test' }

    before do
      allow(Rails.application.credentials)
        .to receive(:cerberus_signing_keys)
        .and_return({ kid => signing_key.public_to_pem })
    end

    # Mint a Cerberus assertion. Defaults are valid; override claims/key/alg/kid
    # per case to exercise the failure modes.
    def assertion(key: signing_key, header_kid: kid, alg: 'ES256', **claims)
      payload = { iss: 'cerberus', aud: 'atlas', sub: privileged.nuid,
                  iat: Time.now.to_i, exp: Time.now.to_i + 30 }.merge(claims)
      JWT.encode(payload, key, alg, { kid: header_kid })
    end

    def bearer(token, extra = {})
      { 'Authorization' => "Bearer #{token}" }.merge(extra)
    end

    it 'resolves the signed sub — the User header is irrelevant on this path' do
      get '/user', headers: bearer(assertion).merge('User' => "NUID #{system_user.nuid}")
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['nuid']).to eq(privileged.nuid)
    end

    it 'rejects an unknown kid (401)' do
      get '/communities', headers: bearer(assertion(header_kid: 'no-such-kid'))
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a signature from a different key (401)' do
      other = OpenSSL::PKey::EC.generate('prime256v1')
      get '/communities', headers: bearer(assertion(key: other))
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects an HS256 alg-confusion forgery using the public key as the HMAC secret (401)' do
      forged = JWT.encode({ iss: 'cerberus', aud: 'atlas', sub: privileged.nuid, exp: Time.now.to_i + 30 },
                          signing_key.public_to_pem, 'HS256', { kid: kid })
      get '/communities', headers: bearer(forged)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects an expired assertion (401)' do
      get '/communities', headers: bearer(assertion(iat: Time.now.to_i - 180, exp: Time.now.to_i - 120))
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a wrong audience (401)' do
      get '/communities', headers: bearer(assertion(aud: 'not-atlas'))
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects an assertion naming the :system fixture (401)' do
      get '/communities', headers: bearer(assertion(sub: system_user.nuid))
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects an assertion for :anonymous (401)' do
      get '/communities', headers: bearer(assertion(sub: anonymous.nuid))
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns 400 for an unknown sub NUID' do
      get '/communities', headers: bearer(assertion(sub: '999999999'))
      expect(response).to have_http_status(:bad_request)
    end

    it 'does not honour acting-as on the assertion path yet: On-Behalf-Of is 403' do
      get '/communities', headers: bearer(assertion, 'On-Behalf-Of' => 'NUID 900000001')
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body['error']).to match(/On-Behalf-Of requires an admin operator/)
    end

    context 'when no keyset is configured (pre-Cerberus-cutover)' do
      before do
        allow(Rails.application.credentials).to receive(:cerberus_signing_keys).and_return(nil)
      end

      it 'leaves the assertion path inert — a cerberus-iss token is 401' do
        get '/communities', headers: bearer(assertion)
        expect(response).to have_http_status(:unauthorized)
      end
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

  describe 'On-Behalf-Of admin gate (acting-as, piece 5)' do
    # Q16: the operator (User header) authorizes; the target (On-Behalf-Of)
    # is only an attribution stamp. So On-Behalf-Of is restricted to admin
    # operators — everyone else presenting it is rejected before the action
    # runs.
    let!(:admin) do
      User.create!(email: 'admin-obo@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000004', name: 'User, Admin', role: :admin)
    end
    let(:target_nuid) { '900000001' }

    def obo_headers(nuid:, token: cerberus_token, on_behalf_of: target_nuid)
      h = auth_headers(token: token, nuid: nuid).merge('Content-Type' => 'application/json')
      h['On-Behalf-Of'] = "NUID #{on_behalf_of}" if on_behalf_of
      h
    end

    it 'rejects a non-admin operator presenting On-Behalf-Of (403)' do
      get '/communities', headers: obo_headers(nuid: privileged.nuid)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body['error']).to match(/On-Behalf-Of requires an admin operator/)
    end

    it 'rejects a guest (no token) presenting On-Behalf-Of (403)' do
      get '/communities', headers: { 'On-Behalf-Of' => "NUID #{target_nuid}" }
      expect(response).to have_http_status(:forbidden)
    end

    it 'rejects the :system principal presenting On-Behalf-Of (403)' do
      get '/communities', headers: obo_headers(token: system_token, nuid: system_user.nuid)
      expect(response).to have_http_status(:forbidden)
    end

    it 'permits an admin operator and attributes the deposit to the target (proxy_uploader null)' do
      post '/works',
           params:  { collection_id: collection.noid, depositor: target_nuid }.to_json,
           headers: obo_headers(nuid: admin.nuid)
      expect(response.status).to be_in([200, 201])

      work = response.parsed_body['work']
      expect(work['depositor']).to      eq(target_nuid)
      expect(work['proxy_uploader']).to be_nil
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

  describe 'admin-only structural mutations (re-parent + linked members)' do
    # An edit-rights staff principal: in the default STAFF_EDIT_GROUP that
    # every Creator stamps onto new resources, so this user holds edit rights
    # on the Work, the source collection, and the destination. Under the old
    # rule (:reparent / linked-members aliased to :update) that was enough to
    # move structure and link members. The tightening makes both admin-only,
    # so even this edit-rights holder now 403s.
    let!(:staff) do
      User.create!(email: 'staff@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000003', name: 'Roe, Sam', role: :privileged,
                   groups: [Permissions::STAFF_EDIT_GROUP])
    end
    let!(:admin) do
      User.create!(email: 'admin-auth@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000004', name: 'User, Admin', role: :admin)
    end

    let(:destination) { CollectionCreator.call(parent_id: community.noid) }
    let(:work)        { WorkCreator.call(parent_id: collection.noid) }

    def json_headers(nuid)
      auth_headers(nuid: nuid).merge('Content-Type' => 'application/json')
    end

    describe 'PATCH /works/:id/parent' do
      it 'denies an edit-rights staff principal with 403' do
        patch "/works/#{work.noid}/parent",
              params: { parent_id: destination.noid }.to_json, headers: json_headers(staff.nuid)
        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body).to include('action' => 'reparent')
      end

      it 'permits the :admin principal' do
        patch "/works/#{work.noid}/parent",
              params: { parent_id: destination.noid }.to_json, headers: json_headers(admin.nuid)
        expect(response).to have_http_status(:ok)
      end
    end

    describe 'POST /works/:id/linked_members' do
      it 'denies an edit-rights staff principal with 403' do
        post "/works/#{work.noid}/linked_members",
             params: { collection_id: destination.noid }.to_json, headers: json_headers(staff.nuid)
        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body).to include('action' => 'link_member')
      end

      it 'permits the :admin principal' do
        post "/works/#{work.noid}/linked_members",
             params: { collection_id: destination.noid }.to_json, headers: json_headers(admin.nuid)
        expect(response).to have_http_status(:ok)
      end
    end

    describe 'DELETE /works/:id/linked_members/:collection_id' do
      before { LinkedMemberCreator.call(work: work, collection: destination) }

      it 'denies an edit-rights staff principal with 403' do
        delete "/works/#{work.noid}/linked_members/#{destination.noid}", headers: json_headers(staff.nuid)
        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body).to include('action' => 'link_member')
      end

      it 'permits the :admin principal' do
        delete "/works/#{work.noid}/linked_members/#{destination.noid}", headers: json_headers(admin.nuid)
        expect(response).to have_http_status(:ok)
      end
    end
  end
end
