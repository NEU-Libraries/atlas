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
    u = User.create(create_params)
    render json: {'message' => 'Success', 'id' => u.id }.to_json, status: 200
  end

  api :GET, '/users/:id', 'Fetch a user'
  param :id, :number, desc: 'id of the requested user'
  def show
    @user = User.find(params[:id])
  end

  api :PATCH, '/users/:id', 'Update a user'
  param :name, String, desc: 'Name of the user - Doe, Jane e.g.'
  def update
    User.find(params[:id]).update(update_params)
    render json: {'message' => "User #{params[:id]} name was updated."}.to_json, status: 200
  end

  api :DELETE, '/users/:id', 'Delete a user'
  param :id, :number, desc: 'id of the user to delete'
  def destroy
    # TODO: restrict to admin user
    User.find(params[:id]).destroy
    render json: {'message' => "User #{params[:id]} was deleted."}.to_json, status: 200
  end

  def index; end

  private

  def create_params
    params.require(:user).permit(:name, :nuid, :email).merge(password: Devise.friendly_token[0, 20])
  end

  def update_params
    params.require(:user).permit(:name)
  end
end
