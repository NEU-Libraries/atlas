# frozen_string_literal: true

require 'rails_helper'

describe WorksController, type: :controller do
  render_views

  after :each do
    Valkyrie.config.metadata_adapter.persister.wipe!
  end

  describe 'GET #show' do
    let(:community) { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }
    let(:work) { WorkCreator.call(parent_id: collection.noid) }
    it 'returns the work details' do
      title = 'Test Title'
      work.plain_title = title
      get :show, params: { id: work.noid }, as: :json
      expect(response).to have_http_status(:success)

      json_response = response.parsed_body
      expect(json_response['work']['id']).to eq(work.noid)
      expect(json_response['work']['title']).to eq(title)
      expect(work.parent.filtered_children.count).to eq(1)
    end
  end

  describe 'GET #mods' do
    let(:community) { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }
    let(:work) { WorkCreator.call(parent_id: collection.noid) }

    it 'displays MODS metadata in JSON for the work' do
      title = 'Mods Test'
      work.plain_title = title
      get :mods, params: { id: work.noid }, as: :json
      expect(response).to have_http_status(:success)
      json_response = response.parsed_body
      expect(json_response['work']).not_to be_empty
      expect(json_response['work']['mods']).not_to be_empty
      expect(json_response['work']['mods']['main_title']['title']).to eq(title)
    end

    it 'displays MODS metadata in HTML for the work' do
      title = 'HTML Test'
      work.plain_title = title
      get :mods, params: { id: work.noid }, as: :html
      expect(response).to have_http_status(:success)
      expect(response.body).to include(title)
    end
  end

  describe 'GET #index' do
    let(:community) { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }

    context 'when works exist' do
      it 'returns a paginated list of all works' do
        12.times do
          WorkCreator.call(parent_id: collection.noid)
        end

        get :index, as: :json
        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        expect(json_response['works']).not_to be_empty
        # TODO: ensure pagination results are correct
      end
    end
  end

  describe 'POST #create' do
    let(:community) { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }

    it 'creates a work with provided collection id as parent' do
      post :create, params: { collection_id: collection.noid }, as: :json
      expect(response).to have_http_status(:success)
      expect(Atlas.query.find_all_of_model(model: Work).count).to eq(1)
      # TODO: Test id is returned and resolves to resource
    end
  end

  describe 'PATCH #update' do
    let(:community) { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }
    let(:work) { WorkCreator.call(parent_id: collection.noid) }

    it 'updates a work with provided XML binary' do
      patch :update, params: { id: work.noid, binary: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) }, as: :json
      expect(response).to have_http_status(:success)
      expect(work.decorate.plain_title).to eq("What's New - How We Respond to Disaster, Episode 1")
    end
  end

  describe 'DELETE #destroy' do
    let(:community) { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }
    let(:work) { WorkCreator.call(parent_id: collection.noid) }

    context 'when work exists' do
      it 'destroys the work' do
        expect(Work.find(work.noid)).to eq(work)
        delete :destroy, params: { id: work.noid }, as: :json
        expect(response).to have_http_status(:success)
        expect(Work.find(work.noid)).to be_nil
      end
    end
  end
end
