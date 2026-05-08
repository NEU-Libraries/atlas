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
      community.plain_title = title
      community.plain_description = description
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

  describe 'PATCH #update' do
    let(:community) { CommunityCreator.call }

    it 'updates a community with provided XML binary' do
      patch :update, params: { id: community.noid, binary: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) }, as: :json
      expect(response).to have_http_status(:success)
      expect(community.decorate.plain_title).to eq("What's New - How We Respond to Disaster, Episode 1")
      # TODO: - switch to community specific fixture XML
    end
  end

  describe 'DELETE #destroy' do
    let(:community) { CommunityCreator.call }

    context 'when community exists' do
      it 'destroys the community' do
        delete :destroy, params: { id: community.noid }, as: :json
        expect(response).to have_http_status(:success)
        expect(Community.find(community.noid)).to be_nil
      end
    end
  end

  describe 'POST #tombstone' do
    let(:community) { CommunityCreator.call }

    it 'tombstones an empty community' do
      request.headers['User'] = 'NUID 000000002'
      post :tombstone, params: { id: community.noid }, as: :json

      expect(response).to have_http_status(:success)
      json = response.parsed_body['community']
      expect(json['tombstoned']).to be(true)
      expect(json['tombstoned_at']).to be_present

      reloaded = Community.find(community.noid)
      expect(reloaded.tombstoned).to be(true)
      expect(reloaded.tombstoned_at).to be_present
    end

    it 'refuses with 422 has_live_children when a live Collection is a member' do
      CollectionCreator.call(parent_id: community.noid)

      post :tombstone, params: { id: community.noid }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['code']).to eq('has_live_children')
      expect(Community.find(community.noid).tombstoned).to be(false)
    end

    it 'succeeds when the only members are themselves tombstoned' do
      child = CollectionCreator.call(parent_id: community.noid)
      child.tombstoned = true
      Atlas.persister.save(resource: child)

      post :tombstone, params: { id: community.noid }, as: :json

      expect(response).to have_http_status(:success)
      expect(Community.find(community.noid).tombstoned).to be(true)
    end
  end

  describe 'POST #restore' do
    let(:community) do
      c = CommunityCreator.call
      c.tombstoned = true
      c.tombstoned_at = Time.current
      c.tombstoned_by = '000000002'
      Atlas.persister.save(resource: c)
    end

    it 'clears tombstone fields' do
      post :restore, params: { id: community.noid }, as: :json

      expect(response).to have_http_status(:success)
      reloaded = Community.find(community.noid)
      expect(reloaded.tombstoned).to be(false)
      expect(reloaded.tombstoned_at).to be_nil
      expect(reloaded.tombstoned_by).to be_nil
    end
  end
end
