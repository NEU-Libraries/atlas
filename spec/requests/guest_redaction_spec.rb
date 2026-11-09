# frozen_string_literal: true

require 'rails_helper'

# A guest is told no NUID, no group but `public`, and no storage path, on every
# route that renders them; a signed-in caller still gets them all. The read and
# Set matrices hold the NUIDs and groups on every route with the cache off; this
# covers each view, the storage paths, and the cache in both fill orders. See
# docs/authorization.md.
#
# default_auth: false, because the global default is the admin.
RSpec.describe 'What a guest is not told', type: :request, default_auth: false do
  let!(:guest) do
    User.find_by(role: :guest) ||
      User.create!(email: 'guest-redaction@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000001', name: 'User, Guest', role: :guest)
  end
  let!(:admin) { ensure_default_admin! }
  let(:owner_nuid)  { '000000091' }
  let(:editor_nuid) { '000000092' }
  let(:group)       { 'northeastern:drs:redaction:editors' }

  def owned(resource)
    resource.depositor = owner_nuid
    resource.proxy_uploader = editor_nuid
    resource.edit_users = [editor_nuid]
    resource.edit_groups = [Permissions::STAFF_EDIT_GROUP, group]
    resource.read_groups = ['public', group]
    Atlas.persister.save(resource: resource)
  end

  let!(:community)  { owned(public_community!) }
  let!(:collection) { owned(CollectionCreator.call(parent_id: community.noid)) }
  let!(:work) do
    w = owned(WorkCreator.call(parent_id: collection.noid))
    DerivativePermissionsUpdater.call(work: w, policy: { 'service' => [group] })
  end
  let!(:blob) do
    source = Rails.root.join('tmp', "redaction-#{SecureRandom.hex(4)}.png")
    FileUtils.cp(Rails.root.join('spec/fixtures/files/example.png'), source)
    BlobCreator.call(path: source.to_s, work_id: work.noid, original_filename: 'example.png')
  end

  after { Atlas.persister.wipe! }

  def body_as(user, path)
    get path, headers: signed_auth_headers(user&.nuid)
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def secrets_in(body)
    text = body.to_json
    [owner_nuid, editor_nuid, group, Permissions::STAFF_EDIT_GROUP].select { |s| text.include?(s) }
  end

  describe 'each view', :response_cache do
    {
      'a Work'       => ->(s) { "/works/#{s.work.noid}" },
      'a Collection' => ->(s) { "/collections/#{s.collection.noid}" },
      'a Community'  => ->(s) { "/communities/#{s.community.noid}" },
      'an ACL'       => ->(s) { "/resources/#{s.work.noid}/permissions" }
    }.each do |what, path|
      it "names no one and no group to a guest on #{what}, after a signed-in caller filled the cache" do
        expect(secrets_in(body_as(admin, path.call(self)))).not_to be_empty
        expect(secrets_in(body_as(nil, path.call(self)))).to be_empty
      end

      it "still names them to a signed-in caller on #{what}, after a guest filled the cache" do
        body_as(nil, path.call(self))
        expect(secrets_in(body_as(admin, path.call(self)))).not_to be_empty
      end
    end
  end

  it "keeps only public in a Work's ACL and tier map for a guest" do
    acl = body_as(nil, "/resources/#{work.noid}/permissions")['resource']
    expect(acl).to include('depositor' => nil, 'proxy_uploader' => nil, 'edit_users' => [],
                           'read' => ['public'], 'edit' => [])
    expect(body_as(nil, "/works/#{work.noid}")['work']['derivative_permissions']).to eq('service' => [])
  end

  it 'tells a guest no storage path for a file' do
    expect(body_as(nil, "/files/#{blob.noid}")['blob']['file_identifiers']).to eq([])
    expect(body_as(admin, "/files/#{blob.noid}")['blob']['file_identifiers']).not_to be_empty
  end

  it 'names no one and no group but public to a guest on a public Set' do
    set = Compilation.create!(title: 'Redaction Set', depositor: owner_nuid)
    set.permissions = { read: ['public', group], edit: [group], edit_users: [editor_nuid] }
    set.save!

    shown = body_as(nil, "/compilations/#{set.noid}")
    expect(secrets_in(shown)).to be_empty
    expect(shown['compilation']).to include('read_groups' => ['public'], 'edit_groups' => [])
    expect(secrets_in(body_as(admin, "/compilations/#{set.noid}"))).not_to be_empty
  end
end
