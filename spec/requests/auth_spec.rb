# frozen_string_literal: true

require 'rails_helper'

# Exercises the auth matrix by hand: the token/header pairing rules and the
# footguns they close — a missing User header must not silently elevate to
# :system, a mismatched token must not fall through to guest, and cross-pairing
# (a user token claiming :system, or a system token claiming a real person)
# must 401. Endpoint authorization beyond auth surfaces as a 403 from Ability.
#
# default_auth: false — this spec drives the auth matrix by hand, so the
# global admin-default in spec/support/auth_request_helper.rb does not apply.
RSpec.describe 'Auth matrix', type: :request, default_auth: false do
  let(:system_token) { 'test-system-token' }

  before do
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

  # Literal header builder for the matrix tests (system_token / bogus / nil).
  # There is no default token on this builder — callers pass one explicitly.
  def auth_headers(token: nil, nuid: nil)
    h = {}
    h['Authorization'] = "Bearer #{token}" unless token.nil?
    h['User']          = "NUID #{nuid}"    if nuid
    h
  end

  describe 'require_auth resolution' do
    it 'returns 401 for an unrecognized bearer token' do
      get '/communities', headers: auth_headers(token: 'definitely-not-the-token')
      expect(response).to have_http_status(:unauthorized)
    end

    it 'falls through to guest when no Authorization header is sent' do
      get '/communities', headers: auth_headers(token: nil)
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'JWT-direct path (standalone-API access)' do
    include ActiveSupport::Testing::TimeHelpers

    # A devise-jwt minted for a real person authenticates directly, no User
    # header — identity lives in the token. Mint with the same encoder POST
    # /nuid uses.
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

  describe 'read_only token scope' do
    let!(:admin) do
      User.create!(email: 'admin-readonly@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000006', name: 'User, Admin', role: :admin)
    end
    let(:work) { WorkCreator.call(parent_id: collection.noid) }

    # Minted for an admin throughout: admin's real Ability grants everything
    # via `manage :all`, so a 403 here proves the read_only floor is
    # independent of the resolved user's own permissions, not just a
    # coincidence of a low-privilege fixture.
    #
    # Mirrors Users::TokensController#nuid's hand-built payload rather than
    # UserEncoder (whose third positional arg is `aud`, not custom claims).
    def mint(user, read_only: false)
      payload = Warden::JWTAuth::PayloadUserHelper.payload_for_user(user, :user).merge('aud' => nil)
      payload['read_only'] = true if read_only
      Warden::JWTAuth::TokenEncoder.new.call(payload)
    end

    def bearer(token)
      { 'Authorization' => "Bearer #{token}" }
    end

    def json(token)
      bearer(token).merge('Content-Type' => 'application/json')
    end

    it 'allows :read — GET /works/:id' do
      get "/works/#{work.noid}", headers: bearer(mint(admin, read_only: true))
      expect(response).to have_http_status(:ok)
    end

    it 'allows :read on the User resource — GET /user' do
      get '/user', headers: bearer(mint(admin, read_only: true))
      expect(response).to have_http_status(:ok)
    end

    it 'allows a read-shaped POST — POST /resources/find_many' do
      post '/resources/find_many', params:  { ids: [work.noid] }.to_json,
                                   headers: json(mint(admin, read_only: true))
      expect(response).to have_http_status(:ok)
    end

    it 'blocks :create even for an admin — POST /works (403)' do
      post '/works', params:  { collection_id: collection.noid }.to_json,
                     headers: json(mint(admin, read_only: true))
      expect(response).to have_http_status(:forbidden)
    end

    it 'blocks :update even for an admin — PATCH /works/:id (403)' do
      patch "/works/#{work.noid}", params:  { title: ['Renamed'] }.to_json,
                                   headers: json(mint(admin, read_only: true))
      expect(response).to have_http_status(:forbidden)
    end

    it 'blocks :destroy even for an admin — DELETE /works/:id (403)' do
      delete "/works/#{work.noid}", headers: bearer(mint(admin, read_only: true))
      expect(response).to have_http_status(:forbidden)
    end

    it 'blocks :reparent even for an admin — PATCH /works/:id/parent (403)' do
      patch "/works/#{work.noid}/parent", params:  { parent_id: collection.noid }.to_json,
                                          headers: json(mint(admin, read_only: true))
      expect(response).to have_http_status(:forbidden)
    end

    it 'does not restrict a token minted without read_only' do
      post '/works', params:  { collection_id: collection.noid }.to_json,
                     headers: json(mint(admin))
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'Cerberus signed-assertion path' do
    let(:signing_key) { OpenSSL::PKey::EC.generate('prime256v1') }
    let(:kid)         { 'cerberus-test' }
    let!(:admin) do
      User.create!(email: 'admin-assert@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000005', name: 'User, Admin', role: :admin)
    end
    let(:obo_target) { '900000001' }

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

    describe 'acting-as via a signed `obo` claim' do
      def create_work(headers)
        post '/works',
             params:  { collection_id: collection.noid }.to_json,
             headers: headers.merge('Content-Type' => 'application/json')
      end

      it 'honours acting-as when an admin operator signs an `obo` claim' do
        create_work(bearer(assertion(sub: admin.nuid, obo: obo_target)))
        expect(response.status).to be_in([200, 201])
        work = response.parsed_body['work']
        expect(work['depositor']).to      eq(obo_target)
        expect(work['proxy_uploader']).to be_nil
      end

      it 'rejects a signed `obo` from a non-admin operator (403)' do
        create_work(bearer(assertion(sub: privileged.nuid, obo: obo_target)))
        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body['error']).to match(/On-Behalf-Of requires an admin operator/)
      end

      it 'ignores a forged On-Behalf-Of *header* — acting-as rides only the signed claim' do
        # Admin operator, NO signed obo, but a header naming a target. The header
        # is overwritten to nil on this path, so the request runs as the operator
        # (depositor = admin), not acting-as the forged target.
        create_work(bearer(assertion(sub: admin.nuid), 'On-Behalf-Of' => "NUID #{obo_target}"))
        expect(response.status).to be_in([200, 201])
        expect(response.parsed_body['work']['depositor']).to eq(admin.nuid)
      end
    end

    # A NUID can hold several accounts (staff/student logins). An optional
    # signed `acct` (email) claim names which one is acting; `sub` stays the
    # NUID. Absent, the preferred account wins, then the oldest.
    describe 'multi-account resolution via a signed `acct` claim' do
      let(:shared_nuid) { '000000055' }
      let!(:staff) do
        User.create!(email: 'p@northeastern.edu', nuid: shared_nuid, name: 'P',
                     password: SecureRandom.hex(16), role: :standard, groups: ['g:staff'])
      end
      let!(:student) do
        User.create!(email: 'p@husky.neu.edu', nuid: shared_nuid, name: 'P',
                     password: SecureRandom.hex(16), role: :standard, groups: ['g:student'])
      end

      it 'acts as the account named by `acct` — its group set, not another\'s' do
        get '/user', headers: bearer(assertion(sub: shared_nuid, acct: 'p@husky.neu.edu'))
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['email']).to  eq('p@husky.neu.edu')
        expect(response.parsed_body['groups']).to eq(['g:student'])
      end

      it 'resolves the preferred account when no `acct` claim is present' do
        student.make_preferred!
        get '/user', headers: bearer(assertion(sub: shared_nuid))
        expect(response.parsed_body['email']).to eq('p@husky.neu.edu')
      end

      it 'falls back to the oldest account when none is preferred and no `acct` is given' do
        get '/user', headers: bearer(assertion(sub: shared_nuid))
        expect(response.parsed_body['email']).to eq('p@northeastern.edu')
      end

      it 'returns 400 when `acct` names an account that is not one of the NUID\'s' do
        get '/user', headers: bearer(assertion(sub: shared_nuid, acct: 'stranger@x.edu'))
        expect(response).to have_http_status(:bad_request)
      end
    end

    context 'when no keyset is configured' do
      before do
        allow(Rails.application.credentials).to receive(:cerberus_signing_keys).and_return(nil)
      end

      it 'leaves the assertion path inert — a cerberus-iss token is 401' do
        get '/communities', headers: bearer(assertion)
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'system_token pairing matrix' do
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

  describe 'On-Behalf-Of header is rejected off the assertion path' do
    # Acting-as now rides a signed `obo` claim (covered in the assertion block).
    # A bare On-Behalf-Of *header* has no legitimate path left except an admin
    # operator on the verified-assertion path, and :system on the system_token
    # path (showcase publishing — covered in its own describe block below).
    let(:obo) { { 'On-Behalf-Of' => 'NUID 900000001' } }

    it 'rejects a guest (no token) presenting On-Behalf-Of (403)' do
      get '/communities', headers: obo
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body['error']).to match(/On-Behalf-Of requires an admin operator/)
    end

    it 'no longer rejects the :system principal presenting On-Behalf-Of at the gate' do
      # The system_token path is a backend-to-backend credential; the gate now
      # trusts it the same way it already trusts the `User: NUID` header there.
      # Nothing on this read action *uses* @on_behalf_of, so it simply falls
      # through to the normal :system read-floor 200 rather than 403ing at the
      # gate itself.
      get '/communities',
          headers: auth_headers(token: system_token, nuid: system_user.nuid).merge(obo)
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'showcase publishing: :system scoped :link_member (system_token + On-Behalf-Of)' do
    let(:destination) { CollectionCreator.call(parent_id: community.noid, featured: true) }
    let(:plain_destination) { CollectionCreator.call(parent_id: community.noid) }
    let(:depositor_nuid) { '000000123' }
    let(:work) { WorkCreator.call(parent_id: collection.noid, depositor: depositor_nuid) }

    def system_headers(on_behalf_of: nil)
      h = auth_headers(token: system_token, nuid: system_user.nuid)
      h['On-Behalf-Of'] = "NUID #{on_behalf_of}" if on_behalf_of
      h.merge('Content-Type' => 'application/json')
    end

    it 'links the Work into the depositor-owned featured showcase' do
      post "/works/#{work.noid}/linked_members",
           params:  { collection_id: destination.noid }.to_json,
           headers: system_headers(on_behalf_of: depositor_nuid)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(destination.noid)
    end

    it 'attributes the resulting AuditEvent to the depositor, not to :system' do
      post "/works/#{work.noid}/linked_members",
           params:  { collection_id: destination.noid }.to_json,
           headers: system_headers(on_behalf_of: depositor_nuid)
      expect(response).to have_http_status(:ok)

      event = AuditEvent.where(action: 'link_member').order(:created_at).last
      expect(event.actor_nuid).to        eq(system_user.nuid)
      expect(event.on_behalf_of_nuid).to eq(depositor_nuid)
    end

    it 'rejects with no On-Behalf-Of at all (403)' do
      post "/works/#{work.noid}/linked_members",
           params:  { collection_id: destination.noid }.to_json,
           headers: system_headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to include('action' => 'link_member')
    end

    it 'rejects when the on_behalf_of NUID does not own the Work (403)' do
      post "/works/#{work.noid}/linked_members",
           params:  { collection_id: destination.noid }.to_json,
           headers: system_headers(on_behalf_of: '000000999')
      expect(response).to have_http_status(:forbidden)
    end

    it 'rejects a non-featured target Collection even with a matching on_behalf_of (403)' do
      post "/works/#{work.noid}/linked_members",
           params:  { collection_id: plain_destination.noid }.to_json,
           headers: system_headers(on_behalf_of: depositor_nuid)
      expect(response).to have_http_status(:forbidden)
    end

    it 'still rejects :system on unrelated Work mutations, even with a matching on_behalf_of' do
      post "/works/#{work.noid}/tombstone", headers: system_headers(on_behalf_of: depositor_nuid)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'Ability-driven 403s on write actions (system_token-paired)' do
    # The :system principal authenticates with system_token. The Ability layer
    # still denies :system on Work creation / mutation; only the wire token used
    # to reach the action changes.
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
      # A create is parent-scoped, so a human principal needs edit rights on the
      # destination: the staff group every Creator stamps onto new resources.
      privileged.update!(groups: [Permissions::STAFF_EDIT_GROUP])
      post '/works',
           params:  { collection_id: collection.noid }.to_json,
           headers: signed_auth_headers(privileged.nuid).merge('Content-Type' => 'application/json')
      expect(response.status).to be_in([200, 201])
    end

    it 'rejects the :system principal on Collection tombstone but permits create' do
      post "/collections/#{collection.noid}/tombstone", headers: system_headers
      expect(response).to have_http_status(:forbidden)

      post '/collections',
           params:  { parent_id: community.noid }.to_json,
           headers: system_headers.merge('Content-Type' => 'application/json')
      expect(response.status).to be_in([200, 201])
    end

    it 'rejects the :system principal on Community tombstone but permits create' do
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

  describe 'admin-only structural mutations (re-parent + linked members + restore)' do
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
    # Devolved-admin tier: :privileged role + Permissions::ADMIN_GROUP, jointly.
    # `staff` above is the role-without-group negative control; `delegate_wrong_role`
    # below is the group-without-role negative control.
    let!(:delegate) do
      User.create!(email: 'delegate@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000042', name: 'Williams, Delegate', role: :privileged,
                   groups: [Permissions::ADMIN_GROUP])
    end
    let!(:delegate_wrong_role) do
      User.create!(email: 'delegate-wrong-role@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000043', name: 'Standard, Delegate', role: :standard,
                   groups: [Permissions::ADMIN_GROUP])
    end

    let(:destination) { CollectionCreator.call(parent_id: community.noid) }
    let(:work)        { WorkCreator.call(parent_id: collection.noid) }

    def json_headers(nuid)
      signed_auth_headers(nuid).merge('Content-Type' => 'application/json')
    end

    describe 'PATCH /collections/:id/parent (devolved-admin tier)' do
      it 'permits the delegate (:privileged + ADMIN_GROUP)' do
        patch "/collections/#{collection.noid}/parent",
              params: { parent_id: destination.noid }.to_json, headers: json_headers(delegate.nuid)
        expect(response).to have_http_status(:ok)
      end

      it 'denies :privileged-without-the-group (staff) with 403' do
        patch "/collections/#{collection.noid}/parent",
              params: { parent_id: destination.noid }.to_json, headers: json_headers(staff.nuid)
        expect(response).to have_http_status(:forbidden)
      end

      it 'denies the-group-without-:privileged with 403' do
        patch "/collections/#{collection.noid}/parent",
              params: { parent_id: destination.noid }.to_json, headers: json_headers(delegate_wrong_role.nuid)
        expect(response).to have_http_status(:forbidden)
      end
    end

    describe 'PATCH /communities/:id/parent (devolved-admin tier)' do
      it 'permits the delegate to move a community to the top of the tree' do
        movable_community = CommunityCreator.call
        patch "/communities/#{movable_community.noid}/parent",
              params: { parent_id: nil }.to_json, headers: json_headers(delegate.nuid)
        expect(response).to have_http_status(:ok)
      end
    end

    describe 'PATCH /works/:id/parent' do
      it 'permits the delegate — the devolved grant covers Work too, even with no Cerberus caller yet' do
        patch "/works/#{work.noid}/parent",
              params: { parent_id: destination.noid }.to_json, headers: json_headers(delegate.nuid)
        expect(response).to have_http_status(:ok)
      end

      it 'denies an edit-rights staff principal with 403' do
        patch "/works/#{work.noid}/parent",
              params: { parent_id: destination.noid }.to_json, headers: json_headers(staff.nuid)
        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body).to include('action' => 'reparent')
      end

      it 'denies the-group-without-:privileged with 403' do
        patch "/works/#{work.noid}/parent",
              params: { parent_id: destination.noid }.to_json, headers: json_headers(delegate_wrong_role.nuid)
        expect(response).to have_http_status(:forbidden)
      end

      it 'permits the :admin principal' do
        patch "/works/#{work.noid}/parent",
              params: { parent_id: destination.noid }.to_json, headers: json_headers(admin.nuid)
        expect(response).to have_http_status(:ok)
      end
    end

    describe 'POST /works/:id/linked_members' do
      it 'denies the delegate with 403 — the devolved grant does not include :link_member' do
        post "/works/#{work.noid}/linked_members",
             params: { collection_id: destination.noid }.to_json, headers: json_headers(delegate.nuid)
        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body).to include('action' => 'link_member')
      end

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

    # Reversing a withdrawal joined this tier: :tombstone still rides edit
    # rights, but :restore is an operator action. `staff` holds edit rights on
    # the Work via STAFF_EDIT_GROUP and could restore it before, so these
    # examples pin a deliberate narrowing rather than a new denial.
    describe 'POST /works/:id/restore' do
      before do
        work.tombstone(by: admin.nuid)
        Atlas.persister.save(resource: work)
      end

      it 'denies an edit-rights staff principal with 403' do
        post "/works/#{work.noid}/restore", headers: json_headers(staff.nuid)
        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body).to include('action' => 'restore')
        expect(Work.find(work.noid).tombstoned).to be(true)
      end

      it 'permits the delegate (:privileged + ADMIN_GROUP)' do
        post "/works/#{work.noid}/restore", headers: json_headers(delegate.nuid)
        expect(response).to have_http_status(:ok)
        expect(Work.find(work.noid).tombstoned).to be(false)
      end

      it 'denies the-group-without-:privileged with 403' do
        post "/works/#{work.noid}/restore", headers: json_headers(delegate_wrong_role.nuid)
        expect(response).to have_http_status(:forbidden)
      end

      it 'permits the :admin principal' do
        post "/works/#{work.noid}/restore", headers: json_headers(admin.nuid)
        expect(response).to have_http_status(:ok)
      end
    end
  end
end
