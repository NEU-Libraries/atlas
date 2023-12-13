# frozen_string_literal: true

# Communities
class CommunitiesController < ApplicationController
  include LazyPagination

  def index
    @pagination, @communities = paginate_model(Community)
  end

  def show
    @community = Community.find(params[:id]).decorate
  end

  def create
    # TODO: XML
    @community = CommunityCreator.call(parent_id: params[:parent_id])
  end

  def mods
    # TODO: support raw XML, in addition to JSON and HTML
    @community = Community.find(params[:id]).decorate
  end

  def children
    @children = Community.find(params[:id]).filtered_children
  end

  def ancestors
    @ancestors = Community.find(params[:id]).ancestors
  end

  def update
    community = Community.find(params[:id])

    file = params[:binary]
    path = file.tempfile.path.presence || file.path
    community.mods_xml = File.read(path)
    @community = Atlas.persister.save(resource: community)
  end

  def destroy
    # TODO: restrict to admin user
    Atlas.persister.delete(resource: Community.find(params[:id]))
  end
end
