# frozen_string_literal: true

require 'rails_helper'

# Parent-scoped create over the wire. The reported hole: a :standard user could
# POST a Collection or Work into a container they had no edit access to — even
# one they could not read — and the resulting child inherited that container's
# ACL, leaving an untitled, un-editable resource inside it (create 200, then
# every subsequent PATCH 403).
#
# Cerberus gates its own create surface, but Atlas is the boundary: a direct API
# caller bypasses that entirely, which is what these examples pin.
#
# default_auth: false — every example names its own principal.
RSpec.describe 'Container create authorization', type: :request, default_auth: false do
  let(:archives) { 'northeastern:drs:library:archives' }
  let(:students) { 'northeastern:drs:library:dsg_students' }

  let(:system_token) { 'test-system-token' }

  before do
    allow(Rails.application.credentials).to receive(:system_token).and_return(system_token)
  end

  let!(:admin) do
    User.create!(email: 'admin-create@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000004', name: 'User, Admin', role: :admin)
  end
  let!(:system_user) do
    User.create!(email: 'system-create@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000000', name: 'User, System', role: :system)
  end
  # The reported actor: a standard user in a group that holds no grant on the
  # fixtures below.
  let!(:student) do
    User.create!(email: 'student@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000005', name: 'Student, Sam', role: :standard, groups: [students])
  end
  let!(:curator) do
    User.create!(email: 'curator-create@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000010', name: 'Reader, Archives', role: :standard, groups: [archives])
  end

  after { Atlas.persister.wipe! }

  def json_headers(nuid)
    signed_auth_headers(nuid).merge('Content-Type' => 'application/json')
  end

  def system_headers
    { 'Authorization' => "Bearer #{system_token}", 'User' => "NUID #{system_user.nuid}",
      'Content-Type' => 'application/json' }
  end

  # A public Community whose only edit grant is the staff group — the shape
  # every Creator leaves behind, and the fixture the reproduction used.
  let(:staff_community) do
    community = CommunityCreator.call
    community.publicize
    Atlas.persister.save(resource: community)
  end
  let(:staff_collection) { CollectionCreator.call(parent_id: staff_community.noid) }

  # A collection the student cannot even read.
  let(:archives_collection) do
    collection = CollectionCreator.call(parent_id: staff_community.noid)
    collection.permissions = { read: [archives], edit: [archives], edit_users: [] }
    Atlas.persister.save(resource: collection)
  end

  describe 'the reported hole' do
    it 'refuses a Collection under a Community the caller cannot edit (403)' do
      post '/collections', params:  { parent_id: staff_community.noid }.to_json,
                           headers: json_headers(student.nuid)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to include('action' => 'create_child', 'subject' => 'Community')
      expect(Atlas.query.find_all_of_model(model: Collection).count).to eq(0)
    end

    it 'refuses a Work under a Collection the caller cannot edit (403)' do
      post '/works', params:  { collection_id: staff_collection.noid }.to_json,
                     headers: json_headers(student.nuid)

      expect(response).to have_http_status(:forbidden)
      expect(Atlas.query.find_all_of_model(model: Work).count).to eq(0)
    end

    it 'refuses a Collection under a Collection the caller cannot read (403)' do
      post '/collections', params:  { parent_id: archives_collection.noid }.to_json,
                           headers: json_headers(student.nuid)

      expect(response).to have_http_status(:forbidden)
    end

    it 'refuses a sub-Community under a Community the caller cannot edit (403)' do
      post '/communities', params:  { parent_id: staff_community.noid }.to_json,
                           headers: json_headers(student.nuid)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'principals who may write into a container' do
    it 'permits a Grouper edit grant on the parent — no personal root needed' do
      post '/collections', params:  { parent_id: archives_collection.noid }.to_json,
                           headers: json_headers(curator.nuid)

      expect(response).to have_http_status(:ok)
    end

    # Ownership rather than ACL: a workspace collection carries edit: [staff]
    # with the owner recorded only as depositor.
    it 'permits the depositor of the parent (deposit into your own workspace)' do
      workspace = CollectionCreator.call(parent_id: staff_community.noid, depositor: student.nuid)

      post '/works', params:  { collection_id: workspace.noid }.to_json,
                     headers: json_headers(student.nuid)

      expect(response).to have_http_status(:ok)
      expect(Work.find(response.parsed_body.dig('work', 'id')).depositor).to eq(student.nuid)
    end

    it 'permits an admin anywhere' do
      post '/collections', params:  { parent_id: archives_collection.noid }.to_json,
                           headers: json_headers(admin.nuid)

      expect(response).to have_http_status(:ok)
    end

    # The seed bootstraps a tree it holds no ACL foothold in, so :system's
    # container grant is unconditional — but still type-scoped.
    it 'permits :system to seed containers while still refusing Works' do
      post '/collections', params: { parent_id: staff_community.noid }.to_json, headers: system_headers
      expect(response).to have_http_status(:ok)

      post '/communities', params: { parent_id: staff_community.noid }.to_json, headers: system_headers
      expect(response).to have_http_status(:ok)

      post '/works', params: { collection_id: staff_collection.noid }.to_json, headers: system_headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to include('action' => 'create', 'subject' => 'Work')
    end
  end

  describe 'parent resolution' do
    it '404s a Collection create with no parent_id (a client error, not a 500)' do
      post '/collections', params: {}.to_json, headers: json_headers(admin.nuid)
      expect(response).to have_http_status(:not_found)
    end

    it '404s a Work create with no collection_id' do
      post '/works', params: {}.to_json, headers: json_headers(admin.nuid)
      expect(response).to have_http_status(:not_found)
    end

    it '404s an unresolvable parent_id' do
      post '/collections', params: { parent_id: 'nope404' }.to_json, headers: json_headers(admin.nuid)
      expect(response).to have_http_status(:not_found)
    end

    # A Community is the one resource that may be parentless, so a blank
    # parent_id there is a top-of-tree create rather than an error.
    it 'still creates a root Community with no parent_id' do
      post '/communities', params: {}.to_json, headers: json_headers(admin.nuid)

      expect(response).to have_http_status(:ok)
      expect(Community.find(response.parsed_body.dig('community', 'id')).parent).to be_nil
    end
  end
end
