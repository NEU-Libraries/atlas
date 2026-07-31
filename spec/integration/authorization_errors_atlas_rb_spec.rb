# frozen_string_literal: true

require 'rails_helper'

# The two refusals Atlas's parent-scoped create and ACL-containment rules
# introduce, driven through atlas_rb over real HTTP (atlas_rb 1.9.3's
# RaiseOnResourceError extension).
#
# Both matter because of what the bindings do WITHOUT a typed error: a create
# unwraps `["collection"]` and hands back nil, so the caller's next `.id` is an
# unhandled 500; a refused permissions write parses into a Mash that reads like
# success, so the edit is silently discarded. The negative case at the end pins
# the discriminator gating — the same PATCH endpoint's other 422s must still
# pass through as plain envelopes.
RSpec.describe 'Authorization and ACL errors via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { '000000004' }
  let(:archives)   { 'northeastern:drs:library:archives' }

  # A standard human with no grant on anything below.
  let!(:outsider) do
    User.create!(email: 'outsider-int@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000005', name: 'Student, Sam', role: :standard,
                 groups: ['northeastern:drs:library:dsg_students'])
  end

  let(:public_community) do
    community = CommunityCreator.call
    community.publicize
    Atlas.persister.save(resource: community)
  end
  let(:collection) { CollectionCreator.call(parent_id: public_community.noid) }

  describe 'a create refused by the container ACL' do
    it 'raises ForbiddenError on Collection.create, naming the container' do
      expect { AtlasRb::Collection.create(public_community.noid, nuid: outsider.nuid) }
        .to raise_error(AtlasRb::ForbiddenError) do |error|
          expect(error.action).to  eq('create_child')
          expect(error.subject).to eq('Community')
        end
    end

    it 'raises ForbiddenError on Work.create' do
      expect { AtlasRb::Work.create(collection.noid, nuid: outsider.nuid) }
        .to raise_error(AtlasRb::ForbiddenError)
    end

    it 'raises ForbiddenError on Community.create' do
      expect { AtlasRb::Community.create(public_community.noid, nuid: outsider.nuid) }
        .to raise_error(AtlasRb::ForbiddenError)
    end

    it 'still returns the created resource when the caller may write there' do
      created = AtlasRb::Collection.create(public_community.noid, nuid: admin_nuid)

      expect(created['id']).to be_present
    end
  end

  describe 'an ACL write refused by containment' do
    # Restricted container with a public child would be the disclosure: the
    # child surfaces in gated discovery while its parent 403s.
    let(:restricted_collection) do
      community = CommunityCreator.call
      community.read_groups = [archives]
      community = Atlas.persister.save(resource: community)

      c = CollectionCreator.call(parent_id: community.noid)
      c.permissions = { read: [archives], edit: [archives], edit_users: [] }
      Atlas.persister.save(resource: c)
    end

    it 'raises PermissionsError instead of returning a success-shaped envelope' do
      error = nil
      begin
        AtlasRb::Collection.metadata(restricted_collection.noid,
                                     { 'permissions' => { 'read' => ['public'] } },
                                     nuid: admin_nuid)
      rescue AtlasRb::PermissionsError => e
        error = e
      end

      expect(error).to be_a(AtlasRb::PermissionsError)
      expect(error.code).to        eq('visibility_exceeds_parent')
      expect(error.resource_id).to eq(restricted_collection.noid)
      expect(Collection.find(restricted_collection.noid).read_groups).not_to include('public')
    end

    it 'raises on a Work under a restricted Collection too' do
      work = WorkCreator.call(parent_id: restricted_collection.noid)

      expect do
        AtlasRb::Work.metadata(work.noid, { 'permissions' => { 'read' => ['public'] } }, nuid: admin_nuid)
      end.to raise_error(AtlasRb::PermissionsError)
    end

    it 'leaves a permitted narrowing alone' do
      result = AtlasRb::Collection.metadata(restricted_collection.noid,
                                            { 'permissions' => { 'read' => [] } },
                                            nuid: admin_nuid)

      expect(result['collection']['id']).to eq(restricted_collection.noid)
    end
  end

  # The gating that keeps the ACL rule from swallowing its neighbours: the same
  # resource surface returns other 422s whose envelopes callers read directly.
  describe 'other refusals on the same endpoints' do
    it 'leaves a non-empty-collection tombstone 422 as a plain envelope' do
      WorkCreator.call(parent_id: collection.noid)

      # No raise: the binding hands back the response for the caller to read.
      response = AtlasRb::Collection.tombstone(collection.noid, nuid: admin_nuid)

      expect(response.status).to eq(422)
      expect(JSON.parse(response.body)['code']).to eq('has_live_children')
      expect(Collection.find(collection.noid).tombstoned).to be(false)
    end
  end
end
