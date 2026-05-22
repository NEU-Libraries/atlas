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
      collection.plain_title = title
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
      collection.plain_title = title
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
end
