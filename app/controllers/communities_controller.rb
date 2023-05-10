# frozen_string_literal: true

# Communities
class CommunitiesController < ApplicationController
  include Pagy::Backend

  def index
    results = Atlas.query.find_all_of_model(model: Community)
    @pagy, @communities = pagy(results, count: results.count)
    @pagination = pagy_metadata(@pagy)
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

    def pagy_get_items(lazy, pagy)
      lazy.drop(pagy.offset).first(pagy.items)
    end
end
