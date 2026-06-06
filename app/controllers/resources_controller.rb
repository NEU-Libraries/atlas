# frozen_string_literal: true

class ResourcesController < ApplicationController
  def show
    authorize! :read, Resource
    @resource = Resource.find(params[:id]).decorate
    redirect_to(@resource)
  end

  def preview
    # An action to facilitate temporary resources - given raw xml give back html
    # Loader preview, XML editor, etc.
    authorize! :preview, Resource
    @resource = Work.new(alternate_ids: [Time.now.to_f.to_s.gsub!('.', '').to_s])
    file = params[:binary]
    path = file.tempfile.path.presence || file.path
    @resource.mods_json = File.read(path)
    @resource.decorate
    # Need to figure out how to clean up any residual objects
    respond_to :html
  end

  def permissions
    authorize! :read, Resource
    @resource = Resource.find(params[:id])
  end

  # Batch resolver. Given a list of noids (or Valkyrie ids), return a
  # lightweight digest per resolvable resource in a single request, so a
  # caller resolving a set of ids no longer fans out to one find per id.
  # Mirrors #show's class-level read floor (Atlas grants :read on every
  # resource to any authenticated principal). Unknown/unresolvable ids are
  # dropped silently; tombstoned resources are kept but flagged, so callers
  # can render a placeholder rather than blow up. Resolution is NOID-first
  # via Resource.find; the win is collapsing N HTTP round-trips into one, not
  # the (cheap, co-located) per-id lookups.
  def find_many
    authorize! :read, Resource
    ids = Array(params[:ids]).map(&:to_s).uniq
    @resources = ids.filter_map { |id| Resource.find(id)&.decorate }
  end
end
