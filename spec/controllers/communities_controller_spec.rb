require 'rails_helper'

RSpec.describe CommunitiesController, type: :controller do
  describe 'GET #show' do
    context 'when the community exists' do
      # let(:user) { create(:user) }

      it 'returns the community details' do
        # get :show, params: { id: user.id }
        # expect(response).to have_http_status(:success)

        # json_response = JSON.parse(response.body)
        # expect(json_response['id']).to eq(user.id)
        # expect(json_response['name']).to eq(user.name)
        # expect(json_response['email']).to eq(user.email)
      end
    end
  end
end
