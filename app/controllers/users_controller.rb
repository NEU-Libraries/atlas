# frozen_string_literal: true

# Users
class UsersController < ApplicationController
  def create
    # TODO: restrict to admin user
    u = User.create(user_params)
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
