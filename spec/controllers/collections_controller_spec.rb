# frozen_string_literal: true

require 'rails_helper'

describe CollectionsController, type: :controller do
  render_views

  after :each do
    Valkyrie.config.metadata_adapter.persister.wipe!
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
      patch :update, params: { id: collection.noid, binary: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) }
      expect(response).to have_http_status(:success)
      expect(collection.decorate.plain_title).to eq("What's New - How We Respond to Disaster, Episode 1")
      expect(collection.parent).to eq(community)
      # TODO - switch to collection specific fixture XML
    end
  end

  describe 'DELETE #destroy' do
    let(:community) { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }

    context 'when collection exists' do
      it 'destroys the collection' do
        expect(Collection.find(collection.noid)).to eq(collection)
        delete :destroy, params: { id: collection.noid }, as: :json
        expect(response).to have_http_status(:success)
        expect(Collection.find(collection.noid)).to be_nil
      end
    end
  end
end
