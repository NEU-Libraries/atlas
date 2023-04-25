# frozen_string_literal: true

# Users
class UsersController < ApplicationController
  def_param_group :user do
    param :user, Hash do
      param :name, String, "Name of the user"
      param :nuid, String, "NEU ID"
    end
  end

  api :POST, "/users", "Create a user"
  param_group :user
  def create
    # TODO: restrict to admin user
    u = User.create(user_params)
    render json: {'id' => u.id}.to_json
  end

  api :GET, '/users/:id'
  param :id, :number, desc: 'id of the requested user'
  def show; end

  def update; end
  def destroy; end
  def index; end

  private

  def user_params
    params.require(:user).permit(:name, :nuid, :email).merge(password: Devise.friendly_token[0,20])
  end
end
