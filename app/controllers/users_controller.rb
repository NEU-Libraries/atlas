# frozen_string_literal: true

# Users
class UsersController < ApplicationController
  def create; end

  api :GET, '/users/:id'
  param :id, :number, desc: 'id of the requested user'
  def show; end

  def update; end
  def destroy; end
  def index; end
end
