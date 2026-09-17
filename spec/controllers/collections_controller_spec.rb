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
  end
end
