# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunitiesController, type: :controller do
  describe 'GET #show' do
    render_views

    context 'when the community exists' do
      let(:community) { CommunityCreator.call }

      it 'returns the community details' do
        get :show, params: { id: community.noid }, as: :json
        expect(response).to have_http_status(:success)

        json_response = JSON.parse(response.body)
        expect(json_response['community']['id']).to eq(community.noid)
      end
    end
  end
end
