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
  end

  describe 'POST #create' do
  end

  describe 'PATCH #update' do
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
