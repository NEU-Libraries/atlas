# frozen_string_literal: true

require 'rails_helper'

# The per-resource read gate, over the wire.
#
# Atlas answered :read unconditionally for any authenticated principal, and
# require_auth resolves a blank token to :guest — so every request in the
# "unauthenticated" block below used to return 200 against a Work with no read
# groups at all, including the binary stream. Each example here is one of those
# requests.
#
# default_auth: false — the global admin default would pass the gate and prove
# nothing.
RSpec.describe 'Per-resource read gate', type: :request, default_auth: false do
  let!(:guest) do
    User.create!(email: 'guest@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000001', name: 'User, Guest', role: :guest)
  end

  # A tree built the way production builds one: the root Community is
  # publicised first, so a public Work below it does not trip
  # PermissionsWriteGuard's containment rule.
  let(:community)  { public_community! }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  # WorkCreator copies the parent's ACL down, and the root here is public, so a
  # Work has to be narrowed explicitly to stand in for a restricted one.
  let(:private_work) do
    work = WorkCreator.call(parent_id: collection.noid)
    work.privatize
    Atlas.persister.save(resource: work)
  end
  let(:public_work) do
    work = WorkCreator.call(parent_id: collection.noid)
    work.publicize
    Atlas.persister.save(resource: work)
  end

  after { Atlas.persister.wipe! }

  describe 'an unauthenticated caller (no Authorization header)' do
    it 'is refused a Work with no read groups' do
      get "/works/#{private_work.noid}"
      expect(response).to have_http_status(:forbidden)
    end

    it 'is still served a public Work' do
      get "/works/#{public_work.noid}"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('work', 'id')).to eq(public_work.noid)
    end

    it 'is refused a private Work ACL envelope' do
      get "/resources/#{private_work.noid}/permissions"
      expect(response).to have_http_status(:forbidden)
    end

    it 'is refused the roll of every Work' do
      get '/works'
      expect(response).to have_http_status(:forbidden)
    end

    it 'is refused the user directory' do
      get '/users', params: { q: 'a' }
      expect(response).to have_http_status(:forbidden)
    end

    # An unknown id must stay a 404. The gate falls back to the class when the
    # find misses, so a miss is not reported as a refusal.
    it 'still answers 404 for an unknown id' do
      get '/works/nosuchnoid'
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'binaries, which the gate resolves through the containing Work' do
    # Deposited while the Work is public, then the Work is narrowed. The Blob
    # keeps the public ACL it was created with — exactly the stale copy the
    # cascade never rewrites — so anything reading the Blob's own read_groups
    # would still serve these bytes.
    let(:blob) do
      work   = public_work
      record = BlobCreator.call(path:              Rails.root.join('spec/fixtures/files/example.png').to_s,
                                work_id:           work.noid,
                                original_filename: 'example.png')
      work.privatize
      Atlas.persister.save(resource: work)
      record
    end

    it 'keeps the leaf\'s own stale copy public, so the walk is what denies' do
      expect(Array(blob.read_groups)).to include('public')
    end

    it 'refuses the Blob record' do
      get "/files/#{blob.noid}"
      expect(response).to have_http_status(:forbidden)
    end

    # The one that matters: the bytes. A Blob keeps the ACL it was created
    # with, so gating on the Blob's own copy would serve these.
    it 'refuses the byte stream' do
      get "/files/#{blob.noid}/content"
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'listings, which filter per row' do
    let!(:private_child) { private_work }
    let!(:public_child)  { public_work }

    it 'omits an unreadable child from a container listing' do
      get "/collections/#{collection.noid}/children"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to     include(public_child.noid)
      expect(response.parsed_body).not_to include(private_child.noid)
    end

    it 'omits an unreadable row from the batch resolver' do
      post '/resources/find_many', params: { ids: [public_child.noid, private_child.noid] }
      expect(response).to have_http_status(:ok)
      noids = response.parsed_body.pluck('noid')
      expect(noids).to     include(public_child.noid)
      expect(noids).not_to include(private_child.noid)
    end
  end

  describe 'a principal holding rights' do
    let!(:editor) do
      User.create!(email: 'editor@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000777', name: 'Doe, Jane', role: :standard,
                   groups: ['northeastern:drs:dataset-editors'])
    end

    # Edit implies read — the grant the write rules already use.
    it 'serves a private Work to a caller in its edit_groups' do
      private_work.edit_groups = editor.groups
      Atlas.persister.save(resource: private_work)

      get "/works/#{private_work.noid}", headers: signed_auth_headers(editor.nuid)
      expect(response).to have_http_status(:ok)
    end

    it 'serves a private Work to an admin' do
      admin = User.create!(email: 'admin2@example.invalid', password: SecureRandom.hex(16),
                           nuid: '000000004', name: 'User, Admin', role: :admin)
      get "/works/#{private_work.noid}", headers: signed_auth_headers(admin.nuid)
      expect(response).to have_http_status(:ok)
    end
  end
end
