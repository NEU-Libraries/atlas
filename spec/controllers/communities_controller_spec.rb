# frozen_string_literal: true

require 'rails_helper'

describe CommunitiesController, type: :controller do
  render_views

  after :each do
    Atlas.persister.wipe!
  end

  describe 'GET #show' do
    let(:community) { CommunityCreator.call }

    context 'when the community exists' do
      it 'returns the community details' do
        get :show, params: { id: community.noid }, as: :json
        expect(response).to have_http_status(:success)

        json_response = response.parsed_body
        expect(json_response['community']['id']).to eq(community.noid)
        expect(community.children.count).to eq(1)
      end
    end
  end

  describe 'GET #index' do
    context 'when communities exists' do
      it 'returns a paginated list of all communities' do
        12.times do
          CommunityCreator.call
        end

        get :index, as: :json
        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        expect(json_response['communities']).not_to be_empty
        # TODO: ensure pagination results are correct
      end
    end
  end

  describe 'GET #mods' do
    let(:community) { CommunityCreator.call }
    it 'displays MODS metadata in JSON for the community' do
      title = 'Mods Test'
      description = 'Mods Description'
      set_mods_primary_title!(community, title)
      set_mods_abstract!(community, description)
      get :mods, params: { id: community.noid }, as: :json
      expect(response).to have_http_status(:success)
      json_response = response.parsed_body
      expect(json_response['community']).not_to be_empty
      expect(json_response['community']['mods']).not_to be_empty
      expect(json_response['community']['mods']['main_title']['title']).to eq(title)
      expect(json_response['community']['mods']['abstract']).to eq(description)
    end
  end

  describe 'POST #create' do
    let(:parent) { CommunityCreator.call }

    it 'creates a community' do
      post :create, params: { parent_id: parent.noid }, as: :json
      expect(response).to have_http_status(:success)
      expect(Atlas.query.find_all_of_model(model: Community).count).to eq(2)
    end
  end

  # A hand-edited /communities/<non-Community-id> must 404, not 500 — Valkyrie's
  # Community.find is not type-scoped, so a Collection id would otherwise reach
  # the Community serializer and blow up. Default principal is the admin fixture
  # (the case that slips past authorization); render_views is on, so the read
  # cases exercise the real jbuilder path.
  describe 'non-Community id is a uniform 404 across the /communities/:id surface' do
    let(:community)  { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }

    it 'GET #show 404s for a non-Community id' do
      get :show, params: { id: collection.noid }, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it 'GET #children 404s for a non-Community id' do
      get :children, params: { id: collection.noid }, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it 'GET #mods 404s for a non-Community id' do
      get :mods, params: { id: collection.noid }, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end
end
