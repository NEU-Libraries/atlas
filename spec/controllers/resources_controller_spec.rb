# frozen_string_literal: true

require 'rails_helper'

# The type-agnostic write surface. Each action resolves the NOID and then does
# what the three typed controllers each used to do, so these examples are the
# per-action coverage that moved off them.
#
# The per-key ACL matrix below is the one worth reading twice: the endpoint
# promises that an omitted key is unchanged, and three different omission
# behaviours used to coexist under that promise.
describe ResourcesController, type: :controller do
  render_views

  after :each do
    Atlas.persister.wipe!
  end

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:mods)       { Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) }

  describe 'PUT #put_mods' do
    it 'replaces the MODS document for each type that holds one' do
      { work => 'work', collection => 'collection', community => 'community' }.each_key do |resource|
        put :put_mods, params: { id: resource.noid, binary: mods }, as: :json

        expect(response).to have_http_status(:success)
        expect(resource.decorate.plain_title).to eq("What's New. How We Respond to Disaster. Episode 1")
      end
    end

    it 'renders the resource in its own typed shape' do
      put :put_mods, params: { id: work.noid, binary: mods }, as: :json

      expect(response.parsed_body.keys).to eq(['work'])
      expect(response.parsed_body.dig('work', 'id')).to eq(work.noid)
    end

    it 'records the editing surface on the audit event when origin is given' do
      put :put_mods, params: { id: work.noid, binary: mods, origin: 'xml_editor' }, as: :json

      expect(AuditEvent.last.payload).to include('source' => 'mods', 'origin' => 'xml_editor')
    end

    # The generic path resolves every type. A type with no MODS answers 404
    # here exactly as it does on the GET.
    it '404s for a type that holds no MODS, without writing' do
      blob = BlobCreator.call(path: Rails.root.join('spec/fixtures/files/example.png').to_s,
                              work_id: work.noid, original_filename: 'example.png')

      expect { put :put_mods, params: { id: blob.parent.noid, binary: mods }, as: :json }
        .not_to change(AuditEvent, :count)
      expect(response).to have_http_status(:not_found)
    end

    it '404s for an unknown id' do
      put :put_mods, params: { id: 'nosuchnoid', binary: mods }, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it '422s when no document is attached' do
      put :put_mods, params: { id: work.noid }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'PATCH #update_permissions' do
    # A full envelope to merge against, so an omitted key has something to
    # preserve. Public root, or the containment rule refuses the read widening.
    let(:community) { public_community! }
    let(:seeded) do
      put_acl(work.noid, 'read' => ['public'], 'edit' => ['northeastern:drs:repository:staff'],
                         'edit_users' => ['000000002'], 'embargo' => '2030-01-15')
      Work.find(work.noid)
    end

    def put_acl(noid, acl)
      patch :update_permissions, params: { id: noid, permissions: acl }, as: :json
      expect(response).to have_http_status(:success)
    end

    def acl_of(noid)
      Work.find(noid).permissions
    end

    it 'applies the keys it is given' do
      put_acl(work.noid, 'read' => ['public'])

      expect(acl_of(work.noid)[:read]).to include('public')
    end

    # The report's regression test, and the reason this endpoint is a PATCH:
    # a payload carrying one key used to blank the others.
    it 'leaves every key it does not carry unchanged' do
      before_acl = seeded.permissions

      put_acl(work.noid, 'read' => [])
      after_acl = acl_of(work.noid)

      expect(after_acl[:read]).to eq([])
      expect(after_acl[:embargo]).to        eq(before_acl[:embargo])
      expect(after_acl[:edit]).to           eq(before_acl[:edit])
      expect(after_acl[:edit_users]).to     eq(before_acl[:edit_users])
      expect(after_acl[:depositor]).to      eq(before_acl[:depositor])
      expect(after_acl[:proxy_uploader]).to eq(before_acl[:proxy_uploader])
    end

    it 'clears a key sent explicitly empty' do
      seeded
      put_acl(work.noid, 'embargo' => '')

      expect(acl_of(work.noid)[:embargo]).to be_nil
    end

    it 'renders the resource in its own typed shape' do
      patch :update_permissions, params: { id: collection.noid, permissions: { 'read' => ['public'] } },
                                 as:     :json

      expect(response.parsed_body.keys).to eq(['collection'])
    end

    it '404s for an unknown id' do
      patch :update_permissions, params: { id: 'nosuchnoid', permissions: { 'read' => [] } }, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'PATCH #update_thumbnails' do
    let(:uri) { 'https://iiif.example/iiif/2/abc/full/!85,85/0/default.jpg' }

    # Make backoff sleeps instantaneous so the retry path adds no wall time.
    before { allow(controller).to receive(:sleep) }

    it 'attaches the Delegate and renders the typed shape' do
      patch :update_thumbnails, params: { id: work.noid, thumbnail: uri }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body.dig('work', 'thumbnail')).to eq(uri)
    end

    it 'retries a transient conflict and still lands the Delegate' do
      calls = 0
      allow(DelegateUpdater).to receive(:call).and_wrap_original do |original, **kwargs|
        calls += 1
        raise Valkyrie::Persistence::StaleObjectError if calls == 1

        original.call(**kwargs)
      end

      patch :update_thumbnails, params: { id: work.noid, thumbnail: uri }, as: :json

      expect(response).to have_http_status(:success)
      expect(calls).to be >= 2
      expect(response.parsed_body.dig('work', 'thumbnail')).to eq(uri)
    end

    it 'surfaces a 409 stale_resource envelope when retries exhaust' do
      allow(DelegateUpdater).to receive(:call).and_raise(Valkyrie::Persistence::StaleObjectError)

      patch :update_thumbnails, params: { id: work.noid, thumbnail: uri }, as: :json

      expect(response).to have_http_status(:conflict)
      json = response.parsed_body
      expect(json['error']).to eq('stale_resource')
      expect(json['resource_id']).to eq(work.noid)
      expect(json['action']).to eq('update_thumbnails')
    end
  end

  describe 'PATCH #update_parent' do
    let(:destination) { CollectionCreator.call(parent_id: community.noid) }

    it 'moves a Work to another Collection' do
      patch :update_parent, params: { id: work.noid, parent_id: destination.noid }, as: :json

      expect(response).to have_http_status(:success)
      expect(Work.find(work.noid).parent.noid).to eq(destination.noid)
    end

    it 'moves a Collection to another Community' do
      other = CommunityCreator.call
      patch :update_parent, params: { id: collection.noid, parent_id: other.noid }, as: :json

      expect(response).to have_http_status(:success)
      expect(Collection.find(collection.noid).parent.noid).to eq(other.noid)
    end

    it '422s an unresolvable destination, which is request input and not the addressed resource' do
      patch :update_parent, params: { id: work.noid, parent_id: 'nosuchnoid' }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq('parent_not_found')
    end
  end

  describe 'POST #tombstone' do
    it 'tombstones a Work regardless of attached FileSets' do
      post :tombstone, params: { id: work.noid }, as: :json

      expect(response).to have_http_status(:success)
      json = response.parsed_body['work']
      expect(json['tombstoned']).to be(true)
      expect(json['tombstoned_at']).to be_present

      reloaded = Work.find(work.noid)
      expect(reloaded.tombstoned).to be(true)
      expect(reloaded.tombstoned_at).to be_present
    end

    it 'refuses a container that still holds live children' do
      work
      post :tombstone, params: { id: collection.noid }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      # `code` carries the machine value on this envelope; `error` is the prose.
      expect(response.parsed_body['code']).to eq('has_live_children')
    end

    it 'succeeds when the only members are themselves tombstoned' do
      child = WorkCreator.call(parent_id: collection.noid)
      child.tombstoned = true
      Atlas.persister.save(resource: child)

      post :tombstone, params: { id: collection.noid }, as: :json

      expect(response).to have_http_status(:success)
      expect(Collection.find(collection.noid).tombstoned).to be(true)
    end

    it 'surfaces a 409 immediately, without retrying' do
      work # persist the chain before stubbing save
      allow(Atlas.persister).to receive(:save).and_raise(Valkyrie::Persistence::StaleObjectError)

      post :tombstone, params: { id: work.noid }, as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['error']).to eq('stale_resource')
      expect(response.parsed_body['action']).to eq('tombstone')
    end

    it '404s for an unknown id' do
      post :tombstone, params: { id: 'nosuchnoid' }, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST #restore' do
    let(:tombstoned) do
      w = WorkCreator.call(parent_id: collection.noid)
      w.tombstone(by: '000000002')
      Atlas.persister.save(resource: w)
    end

    it 'clears the tombstone fields' do
      post :restore, params: { id: tombstoned.noid }, as: :json

      expect(response).to have_http_status(:success)
      reloaded = Work.find(tombstoned.noid)
      expect(reloaded.tombstoned).to be(false)
      expect(reloaded.tombstoned_at).to be_nil
      expect(reloaded.tombstoned_by).to be_nil
    end
  end

  describe 'DELETE #destroy' do
    it 'purges the resource' do
      delete :destroy, params: { id: work.noid }, as: :json

      expect(response).to have_http_status(:success)
      expect(Work.find(work.noid)).to be_nil
    end

    it 'cascades into its FileSets and Blobs' do
      blob      = BlobCreator.call(path: Rails.root.join('spec/fixtures/files/example.png').to_s,
                                   work_id: work.noid, original_filename: 'example.png')
      file_sets = work.children.grep(FileSet)

      delete :destroy, params: { id: work.noid }, as: :json

      expect(Blob.find(blob.noid)).to be_nil
      file_sets.each { |fs| expect(FileSet.find(fs.noid)).to be_nil }
    end

    it 'audits the destroy with the purge manifest' do
      expect { delete :destroy, params: { id: work.noid }, as: :json }
        .to change(AuditEvent, :count).by(1)

      event = AuditEvent.last
      expect(event.action).to eq('destroy')
      expect(event.payload['purged']).to include(work.noid)
    end

    it 'refuses a container with a live member' do
      WorkCreator.call(parent_id: collection.noid)

      delete :destroy, params: { id: collection.noid }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['code']).to eq('has_children')
      expect(Collection.find(collection.noid)).not_to be_nil
    end

    # Diverges from tombstone, which allows this. A purge cannot be undone, so
    # a tombstoned member left behind is orphaned for good.
    it 'refuses a container with a tombstoned member too' do
      child = WorkCreator.call(parent_id: collection.noid)
      child.tombstone(by: '000000004')
      Atlas.persister.save(resource: child)

      delete :destroy, params: { id: collection.noid }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['code']).to eq('has_children')
    end

    # Every container is minted with one, so it must not read as a member.
    it 'ignores the container’s own descriptive-metadata FileSet' do
      expect(collection.children.grep(FileSet)).not_to be_empty

      delete :destroy, params: { id: collection.noid }, as: :json

      expect(response).to have_http_status(:success)
    end

    it '404s for an unknown id' do
      delete :destroy, params: { id: 'nosuchnoid' }, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  # Re-parenting is an admin-only structural mutation: edit rights are not
  # sufficient, even on BOTH the moved node and the destination. The mover is a
  # privileged principal carrying a custom edit group (not the default staff
  # group every container is seeded with) so explicit edit rights can be
  # granted and shown still not to unlock the move.
  describe 'PATCH #update_parent (admin-only authz gate)' do
    let(:edit_group) { 'northeastern:drs:special-movers' }
    let!(:mover) do
      User.create!(email: "mover-#{SecureRandom.hex(4)}@example.invalid",
                   password: SecureRandom.hex(16), nuid: '000000777',
                   name: 'User, Mover', role: :privileged, groups: [edit_group])
    end

    let(:destination) { CollectionCreator.call(parent_id: community.noid) }

    def grant!(resource)
      resource.add_edit_group(edit_group)
      Atlas.persister.save(resource: resource)
    end

    it 'forbids an edit-rights principal with edit rights on BOTH node and destination' do
      grant!(collection)
      grant!(destination)
      # Act as the edit-rights (non-admin) principal: override the default admin
      # assertion with one whose sub is the mover.
      request.headers['Authorization'] = "Bearer #{DefaultAuthHeaders.assertion_for(mover.nuid)}"

      patch :update_parent, params: { id: collection.noid, parent_id: destination.noid }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(Collection.find(collection.noid).parent.noid).to eq(community.noid) # unmoved
    end

    it 'allows the move for an admin' do
      patch :update_parent, params: { id: collection.noid, parent_id: destination.noid }, as: :json

      expect(response).to have_http_status(:success)
      expect(Collection.find(collection.noid).parent.noid).to eq(destination.noid)
    end
  end
end
