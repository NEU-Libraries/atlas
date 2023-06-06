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
      title = "Test Title"
      work.plain_title = title
      get :show, params: { id: work.noid }, as: :json
      expect(response).to have_http_status(:success)

      json_response = JSON.parse(response.body)
      expect(json_response['work']['id']).to eq(work.noid)
      expect(json_response['work']['title']).to eq(title)
    end
  end

  describe 'GET #index' do
  end

  describe 'POST #create' do
  end

  describe 'PATCH #update' do
  end

  describe 'DELETE #destroy' do
  end
end
