# frozen_string_literal: true

require 'rails_helper'

describe UsersController, type: :controller do
  render_views

  before(:each) do
    User.destroy_all
  end

  describe 'GET #show' do
    let(:user) { User.create(:email => Faker::Internet.email, :password => Devise.friendly_token[0, 20], name: Faker::Name.name, nuid: Random.rand(10000).to_s) }

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
    context 'when users exists' do
      it 'returns a paginated list of all users' do
        12.times do
          User.create(:email => Faker::Internet.email, :password => Devise.friendly_token[0, 20], name: Faker::Name.name, nuid: Random.rand(10000).to_s)
        end

        get :index, as: :json
        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        expect(json_response['users']).not_to be_empty
        # TODO: ensure pagination results are correct
      end
    end
  end

  describe 'POST #create' do
    it 'creates a user' do
      post :create, params: { name: Faker::Name.name, nuid: Random.rand(10000).to_s, email: Faker::Internet.email}, as: :json
      expect(response).to have_http_status(:success)
      expect(User.count).to eq(1)
      # TODO: test return user id
    end
  end

  describe 'PATCH #update' do
    let(:user) { User.create(:email => Faker::Internet.email, :password => Devise.friendly_token[0, 20], name: 'Old Name', nuid: Random.rand(10000).to_s) }

    it 'updates a user with a new name' do
      patch :update, params: {id: user.id.to_s, user: {name: 'New Name'}}
      expect(response).to have_http_status(:success)
      expect(User.find(user.id).name).to eq('New Name')
    end
  end

  describe 'DELETE #destroy' do
    let(:user) { User.create(:email => Faker::Internet.email, :password => Devise.friendly_token[0, 20], name: Faker::Name.name, nuid: Random.rand(10000).to_s) }

    context 'when user exists' do
      it 'destroys the user' do
        expect(User.find(user.id)).to eq(user)
        delete :destroy, params: { id: user.id }, as: :json
        expect(response).to have_http_status(:success)
        expect{User.find(user.id)}.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
