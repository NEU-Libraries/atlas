# frozen_string_literal: true

# Communities
class CommunitiesController < ApplicationController
  include Pagy::Backend

  def index
    # TODO: implement pagination
    @communities = Atlas.query.find_all_of_model(model: Community).to_a
  end
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
    community.mods_xml = parse_xml
  end
  def destroy
    # TODO: restrict to admin user
    Atlas.persister.delete(resource: Community.find(params[:id]))
  end

  private

    def update_params
      params.require(:community).permit(:xml)
    end

    def parse_xml
      Base64.decode64(params[:community][:xml])
    end
end
