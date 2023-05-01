# frozen_string_literal: true

# Communities
class CommunitiesController < ApplicationController
  def index; end
  def show
    @community = Community.find(params[:id])
  end
  def create
    # TODO: title and description params
    community = CommunityCreator.call()
  end
  def update; end
  def destroy; end
end
