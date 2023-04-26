# frozen_string_literal: true

# Users
class UsersController < ApplicationController
  api :POST, '/users', 'Create a user'
  param :name, String, 'Name of the user'
  param :nuid, String, 'NEU ID'
  returns code: 200, desc: 'a successful response' do
    property :id, String, desc: 'User ID'
  end
  def create
    # TODO: restrict to admin user
    u = User.create(user_params)
    render json: {'message' => 'success', 'id' => u.id }.to_json, status: 200
  end

  api :GET, '/users/:id'
  param :id, :number, desc: 'id of the requested user'
  def show
    @user = User.find(params[:id])
  end

  def update; end

  def destroy
    # TODO: restrict to admin user
    User.find(params[:id]).destroy
    render json: {'message' => "User #{params[:id]} was deleted."}.to_json, status: 200
  end

  def index; end

  private

  def user_params
    params.require(:user).permit(:name, :nuid, :email).merge(password: Devise.friendly_token[0, 20])
  end
end
