# frozen_string_literal: true

require 'rails_helper'

describe UsersController, type: :controller do
  render_views

  before(:each) do
    User.destroy_all
  end

  describe 'GET #show' do
    let(:user) { User.create(:email => "test@email.com", :password => "drs12345", :password_confirmation => "drs12345", name:"Temp User", nuid:"000000000") }

    context 'when the user exists' do
      it 'returns the user details' do
        expect(user.id).to be_a_kind_of(Integer)
        get :show, params: { id: user.id }, as: :json
        expect(response).to have_http_status(:success)

        json_response = response.parsed_body
        expect(json_response['user']['id']).to eq(user.id)
      end
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
