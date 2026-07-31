# frozen_string_literal: true

require 'rails_helper'

# The ACL write rules over the wire, on the shared `PATCH /{resource}/:id`
# metadata funnel (Auditable -> PermissionsWriteGuard). Two rules:
#
#   * a resource may be no more visible than its container (422), and
#   * a group grant may only be removed by a member of that group (merged back).
#
# Atlas is the boundary here: Cerberus scopes its own permissions form, but a
# crafted PATCH that simply omits a row would otherwise remove the grant.
#
# default_auth: false — these examples switch principals per case.
RSpec.describe 'Permissions write rules', type: :request, default_auth: false do
  let(:archives) { 'northeastern:drs:library:archives' }
  let(:marcom)   { 'northeastern:drs:library:marcom' }

  let!(:admin) do
    User.create!(email: 'admin-acl@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000004', name: 'User, Admin', role: :admin)
  end
  # Devolved admin who also curates archives — the group is what gets them
  # :update on the fixture at all, the tier is what exempts them from the
  # grant-removal rule.
  let!(:delegate) do
    User.create!(email: 'delegate-acl@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000042', name: 'Williams, Delegate', role: :privileged,
                 groups: [Permissions::ADMIN_GROUP, archives])
  end
  # An archives curator: edit rights via Grouper on the fixtures below.
  let!(:curator) do
    User.create!(email: 'curator-acl@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000010', name: 'Reader, Archives', role: :standard,
                 groups: [archives])
  end

  after { Atlas.persister.wipe! }

  def json_headers(nuid)
    signed_auth_headers(nuid).merge('Content-Type' => 'application/json')
  end

  def patch_permissions(path, nuid, permissions)
    patch path, params: { metadata: { permissions: permissions } }.to_json, headers: json_headers(nuid)
  end

  # A root Community whose read audience is `read`, with a Collection under it
  # carrying the same ACL plus an archives edit grant.
  def restricted_tree(read:)
    community = CommunityCreator.call
    community.read_groups = read
    community = Atlas.persister.save(resource: community)

    collection = CollectionCreator.call(parent_id: community.noid)
    collection.permissions = { read: read, edit: [archives], edit_users: [] }
    [community, Atlas.persister.save(resource: collection)]
  end

  describe 'visibility containment' do
    it 'refuses a public read on a Collection inside a restricted Community (422)' do
      _community, collection = restricted_tree(read: [archives])

      patch_permissions("/collections/#{collection.noid}", admin.nuid, { read: ['public'], edit: [archives] })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include('error' => 'visibility_exceeds_parent')
      expect(Collection.find(collection.noid).read_groups).not_to include('public')
    end

    it 'refuses a Work made public inside a restricted Collection (422)' do
      _community, collection = restricted_tree(read: [archives])
      work = WorkCreator.call(parent_id: collection.noid)

      patch_permissions("/works/#{work.noid}", admin.nuid, { read: ['public'], edit: [archives] })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Work.find(work.noid).read_groups).not_to include('public')
    end

    it 'refuses a read group the container does not grant (422)' do
      _community, collection = restricted_tree(read: [archives])

      patch_permissions("/collections/#{collection.noid}", admin.nuid,
                        { read: [archives, marcom], edit: [archives] })

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'permits narrowing, and permits any audience under a public container' do
      _community, collection = restricted_tree(read: [archives])
      patch_permissions("/collections/#{collection.noid}", admin.nuid, { read: [], edit: [archives] })
      expect(response).to have_http_status(:ok)

      public_community = CommunityCreator.call
      public_community.publicize
      public_community = Atlas.persister.save(resource: public_community)
      child = CollectionCreator.call(parent_id: public_community.noid)

      patch_permissions("/collections/#{child.noid}", admin.nuid, { read: ['public'], edit: [] })
      expect(response).to have_http_status(:ok)
      expect(Collection.find(child.noid).read_groups).to include('public')
    end

    # A data invariant, not an authorization tier: the examples above show an
    # admin refused, and an edit-rights curator is refused identically. A public
    # child in a restricted container is discoverable and downloadable while its
    # parent 403s, so the correct fix is always to widen the parent.
    it 'refuses an edit-rights curator the same way it refuses an admin' do
      _community, collection = restricted_tree(read: [archives])

      patch_permissions("/collections/#{collection.noid}", curator.nuid, { read: ['public'], edit: [archives] })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include('error' => 'visibility_exceeds_parent')
    end

    it 'leaves a root Community unconstrained' do
      community = CommunityCreator.call

      patch_permissions("/communities/#{community.noid}", admin.nuid, { read: ['public'], edit: [] })

      expect(response).to have_http_status(:ok)
      expect(Community.find(community.noid).read_groups).to include('public')
    end
  end

  describe 'grant removal' do
    # Public tree so the read assertions aren't entangled with containment.
    let(:collection) do
      community = CommunityCreator.call
      community.publicize
      community = Atlas.persister.save(resource: community)

      c = CollectionCreator.call(parent_id: community.noid)
      c.permissions = { read: ['public', archives], edit: [archives, marcom], edit_users: [] }
      Atlas.persister.save(resource: c)
    end

    it 'preserves a grant the caller is not a member of, rather than 403ing' do
      patch_permissions("/collections/#{collection.noid}", curator.nuid,
                        { read: ['public', archives], edit: [archives] })

      expect(response).to have_http_status(:ok)
      saved = Collection.find(collection.noid)
      expect(saved.edit_groups).to include(marcom)
    end

    it 'lets the caller remove a grant for their own group' do
      patch_permissions("/collections/#{collection.noid}", curator.nuid,
                        { read: ['public'], edit: [marcom] })

      expect(response).to have_http_status(:ok)
      saved = Collection.find(collection.noid)
      expect(saved.edit_groups).not_to include(archives)
      expect(saved.read_groups).not_to include(archives)
    end

    it 'lets the devolved-admin tier remove a grant for a group it is not in' do
      patch_permissions("/collections/#{collection.noid}", delegate.nuid,
                        { read: ['public'], edit: [archives] })

      expect(response).to have_http_status(:ok)
      expect(Collection.find(collection.noid).edit_groups).not_to include(marcom)
    end

    it 'lets an admin remove any grant' do
      patch_permissions("/collections/#{collection.noid}", admin.nuid, { read: ['public'], edit: [] })

      expect(response).to have_http_status(:ok)
      saved = Collection.find(collection.noid)
      expect(saved.edit_groups).not_to include(archives, marcom)
    end

    # A preserved grant means the effective ACL didn't change, so the no-op
    # suppression in Auditable must leave the Rights history clean.
    it 'writes no permissions audit row when the only difference was preserved' do
      collection # create before counting

      expect do
        patch_permissions("/collections/#{collection.noid}", curator.nuid,
                          { read: ['public', archives], edit: [archives] })
      end.not_to change { AuditEvent.for_resource(collection.id).where(change_type: 'permissions').count }
    end
  end
end
