# frozen_string_literal: true

require 'rails_helper'

describe CollectionsController, type: :controller do
  render_views

  after :each do
    Atlas.persister.wipe!
  end

  describe 'GET #show' do
    let(:community) { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }

    it 'returns the collection details' do
      title = 'Test Title'
      set_mods_primary_title!(collection, title)
      get :show, params: { id: collection.noid }, as: :json
      expect(response).to have_http_status(:success)

      json_response = response.parsed_body
      expect(json_response['collection']['id']).to eq(collection.noid)
      expect(json_response['collection']['title']).to eq(title)
    end
  end

  describe 'GET #mods' do
    let(:community) { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }

    it 'displays MODS metadata in JSON for the collection' do
      title = 'Mods Test'
      set_mods_primary_title!(collection, title)
      get :mods, params: { id: collection.noid }, as: :json
      expect(response).to have_http_status(:success)
      json_response = response.parsed_body
      expect(json_response['collection']).not_to be_empty
      expect(json_response['collection']['mods']).not_to be_empty
      expect(json_response['collection']['mods']['main_title']['title']).to eq(title)
    end
  end

  describe 'GET #index' do
    let(:community) { CommunityCreator.call }
    context 'when collections exist' do
      it 'returns a paginated list of all collections' do
        12.times do
          CollectionCreator.call(parent_id: community.noid)
        end

        get :index, as: :json
        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        expect(json_response['collections']).not_to be_empty
        # TODO: ensure pagination results are correct
      end
    end
  end

  describe 'POST #create' do
    let(:parent) { CommunityCreator.call }

    it 'creates a collection' do
      post :create, params: { parent_id: parent.noid }, as: :json
      expect(response).to have_http_status(:success)
      expect(Atlas.query.find_all_of_model(model: Collection).count).to eq(1)
    end
  end

  describe 'PATCH #update' do
    let(:community) { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }

    it 'updates a collection with provided XML binary' do
      patch :update, params: { id: collection.noid, binary: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) }, as: :json
      expect(response).to have_http_status(:success)
      expect(collection.decorate.plain_title).to eq("What's New - How We Respond to Disaster, Episode 1")
      expect(collection.parent.noid).to eq(community.noid)
      # TODO: - switch to collection specific fixture XML
    end
  end

  describe 'DELETE #destroy' do
    let(:community) { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }

    context 'when collection exists' do
      it 'destroys the collection' do
        delete :destroy, params: { id: collection.noid }, as: :json
        expect(response).to have_http_status(:success)
        expect(Collection.find(collection.noid)).to be_nil
      end

      it 'audits the destroy' do
        expect { delete :destroy, params: { id: collection.noid }, as: :json }
          .to change(AuditEvent, :count).by(1)
        expect(AuditEvent.last.action).to eq('destroy')
      end
    end

    context 'when the collection still has members' do
      it 'refuses a live member' do
        WorkCreator.call(parent_id: collection.noid)

        delete :destroy, params: { id: collection.noid }, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['code']).to eq('has_children')
        expect(Collection.find(collection.noid)).not_to be_nil
      end

      # Diverges from tombstone, which allows this. A purge cannot be undone,
      # so a tombstoned member left behind is orphaned for good.
      it 'refuses a tombstoned member too' do
        work = WorkCreator.call(parent_id: collection.noid)
        work.tombstone(by: '000000004')
        Atlas.persister.save(resource: work)

        delete :destroy, params: { id: collection.noid }, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['code']).to eq('has_children')
      end

      # Every container is minted with one, so it must not read as a member.
      it 'ignores its own descriptive-metadata FileSet' do
        expect(collection.children.select { |c| c.is_a?(FileSet) }).not_to be_empty

        delete :destroy, params: { id: collection.noid }, as: :json

        expect(response).to have_http_status(:success)
      end
    end
  end

  describe 'POST #tombstone' do
    let(:community)  { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }

    it 'tombstones an empty collection' do
      post :tombstone, params: { id: collection.noid }, as: :json

      expect(response).to have_http_status(:success)
      json = response.parsed_body['collection']
      expect(json['tombstoned']).to be(true)
      expect(Collection.find(collection.noid).tombstoned).to be(true)
    end

    it 'refuses with 422 has_live_children when a live Work is a member' do
      WorkCreator.call(parent_id: collection.noid)

      post :tombstone, params: { id: collection.noid }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['code']).to eq('has_live_children')
      expect(Collection.find(collection.noid).tombstoned).to be(false)
    end

    it 'succeeds when the only members are themselves tombstoned' do
      child = WorkCreator.call(parent_id: collection.noid)
      child.tombstoned = true
      Atlas.persister.save(resource: child)

      post :tombstone, params: { id: collection.noid }, as: :json

      expect(response).to have_http_status(:success)
      expect(Collection.find(collection.noid).tombstoned).to be(true)
    end
  end

  describe 'POST #restore' do
    let(:community) { CommunityCreator.call }
    let(:collection) do
      c = CollectionCreator.call(parent_id: community.noid)
      c.tombstoned = true
      c.tombstoned_at = Time.current
      c.tombstoned_by = '000000002'
      Atlas.persister.save(resource: c)
    end

    it 'clears tombstone fields' do
      post :restore, params: { id: collection.noid }, as: :json

      expect(response).to have_http_status(:success)
      reloaded = Collection.find(collection.noid)
      expect(reloaded.tombstoned).to be(false)
      expect(reloaded.tombstoned_at).to be_nil
      expect(reloaded.tombstoned_by).to be_nil
    end
  end

  describe 'PATCH #update_parent (admin-only authz gate)' do
    # Re-parenting is an admin-only structural mutation: edit rights are not
    # sufficient, even on BOTH the moved node and the destination. The mover
    # is a privileged principal carrying a custom edit group (not the default
    # staff group every container is seeded with) so we can grant explicit
    # edit rights and prove they still don't unlock the move.
    let(:edit_group) { 'northeastern:drs:special-movers' }
    let!(:mover) do
      User.create!(email: "mover-#{SecureRandom.hex(4)}@example.invalid",
                   password: SecureRandom.hex(16), nuid: '000000777',
                   name: 'User, Mover', role: :privileged, groups: [edit_group])
    end

    let(:community)   { CommunityCreator.call }
    let(:destination) { CollectionCreator.call(parent_id: community.noid) }
    let(:collection)  { CollectionCreator.call(parent_id: community.noid) }

    def grant!(resource)
      resource.add_edit_group(edit_group)
      Atlas.persister.save(resource: resource)
    end

    it 'forbids an edit-rights principal even with edit rights on BOTH node and destination' do
      grant!(collection)
      grant!(destination)
      # Act as the edit-rights (non-admin) principal: override the default admin
      # assertion with one whose sub is the mover (the User header is ignored now).
      request.headers['Authorization'] = "Bearer #{DefaultAuthHeaders.assertion_for(mover.nuid)}"

      patch :update_parent, params: { id: collection.noid, parent_id: destination.noid }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(Collection.find(collection.noid).parent.noid).to eq(community.noid) # unmoved
    end

    it 'allows the move for an admin' do
      # Default controller principal is the admin fixture (NUID 000000004).
      patch :update_parent, params: { id: collection.noid, parent_id: destination.noid }, as: :json

      expect(response).to have_http_status(:success)
      expect(Collection.find(collection.noid).parent.noid).to eq(destination.noid)
    end
  end

  # A hand-edited /collections/<non-Collection-id> must 404, not 500 — Valkyrie's
  # Collection.find is not type-scoped, so a Community id would otherwise reach
  # the Collection serializer and blow up. Default principal is the admin
  # fixture (the case that slips past authorization); render_views is on, so the
  # read cases exercise the real jbuilder path.
  describe 'non-Collection id is a uniform 404 across the /collections/:id surface' do
    let(:community) { CommunityCreator.call }

    it 'GET #show 404s for a non-Collection id' do
      get :show, params: { id: community.noid }, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it 'GET #children 404s for a non-Collection id' do
      get :children, params: { id: community.noid }, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it 'GET #mods 404s for a non-Collection id' do
      get :mods, params: { id: community.noid }, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it 'POST #tombstone 404s for a non-Collection id (admin) instead of mutating it' do
      post :tombstone, params: { id: community.noid }, as: :json
      expect(response).to have_http_status(:not_found)
      expect(Community.find(community.noid).tombstoned).to be_falsey
    end
  end
end
