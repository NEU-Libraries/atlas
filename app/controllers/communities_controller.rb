# frozen_string_literal: true

# Communities
class CommunitiesController < ApplicationController
  def index; end
  def show; end
  def create
    community = CommunityCreator.call()
  end
  def update; end
  def destroy; end
end
