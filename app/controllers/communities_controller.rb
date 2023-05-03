# frozen_string_literal: true

# Communities
class CommunitiesController < ApplicationController
  def index; end
  def show
    @community = Community.find(params[:id]).decorate
  end
  def create
    # TODO: XML
    community = CommunityCreator.call()
  end
  def mods
    @community = Community.find(params[:id]).decorate
  end
  def update
    community = Community.find(params[:id])
    updated_mods = Base64.decode64(params[:community][:xml])
    community.mods_xml = updated_mods
  end
  def destroy
    # TODO: restrict to admin user
    Atlas.persister.delete(resource: Community.find(params[:id]))
  end

  private

    def update_params
      params.require(:community).permit(:xml)
    end
end
