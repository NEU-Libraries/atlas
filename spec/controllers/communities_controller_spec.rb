# frozen_string_literal: true

require 'rails_helper'

describe CommunitiesController, type: :controller do
  render_views

  after :each do
    Valkyrie.config.metadata_adapter.persister.wipe!
  end

  describe 'GET #show' do
    let(:community) { CommunityCreator.call }

    context 'when the community exists' do
      it 'returns the community details' do
        get :show, params: { id: community.noid }, as: :json
        expect(response).to have_http_status(:success)

        json_response = response.parsed_body
        expect(json_response['community']['id']).to eq(community.noid)
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
      community.plain_title = title
      get :mods, params: { id: community.noid }, as: :json
      expect(response).to have_http_status(:success)
      json_response = response.parsed_body
      expect(json_response['community']).not_to be_empty
      expect(json_response['community']['mods']).not_to be_empty
      expect(json_response['community']['mods']['main_title']['title']).to eq(title)
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

  describe 'PATCH #update' do
    let(:community) { CommunityCreator.call }

    it 'updates a community with provided XML binary' do
      patch :update, params: { id: community.noid, binary: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) }
      expect(response).to have_http_status(:success)
      expect(community.decorate.plain_title).to eq("What's New - How We Respond to Disaster, Episode 1")
      # TODO - switch to community specific fixture XML
    end
  end

  describe 'DELETE #destroy' do
    let(:community) { CommunityCreator.call }

    context 'when community exists' do
      it 'destroys the community' do
        expect(Community.find(community.noid)).to eq(community)
        delete :destroy, params: { id: community.noid }, as: :json
        expect(response).to have_http_status(:success)
        expect(Community.find(community.noid)).to be_nil
      end
    end
  end
end
