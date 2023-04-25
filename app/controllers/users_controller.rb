# frozen_string_literal: true

# Users
class UsersController < ApplicationController
  def create
    # User.create(:password => Devise.friendly_token[0,20], full_name:"Temp User", nuid:"000000000")
  end

  api :GET, '/users/:id'
  param :id, :number, desc: 'id of the requested user'
  def show; end

  def update; end
  def destroy; end
  def index; end
end
