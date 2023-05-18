# frozen_string_literal: true

require 'rails_helper'

describe CommunitiesController, type: :controller do
  render_views

  let(:community) { CommunityCreator.call }

  describe 'GET #show' do
    context 'when the community exists' do
      it 'returns the community details' do
        get :show, params: { id: community.noid }, as: :json
        expect(response).to have_http_status(:success)

        json_response = JSON.parse(response.body)
        expect(json_response['community']['id']).to eq(community.noid)
      end
    end
  end

  describe 'GET #index' do
  end

  describe 'GET #mods' do
  end

  describe 'POST #create' do
  end

  describe 'PATCH #update' do
  end

  describe 'DELETE #destroy' do
  end
end
