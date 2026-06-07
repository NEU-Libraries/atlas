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

  # MODS version history for any Modsable resource. The descriptor list
  # carries audit-derived actor attribution (who edited, when), the same
  # provenance /history exposes — so it is admin-gated identically
  # (:read, AuditEvent), not on the public resource read floor. Empty/absent
  # MODS (or a non-Modsable / unresolvable id) yields an empty array, never a
  # 404 — mirrors /history's "no events" shape.
  def mods_versions
    authorize! :read, AuditEvent
    @resource_id = params[:id]
    @versions = MODSVersionHistory.descriptors(resource: Resource.find(@resource_id))
  end

  # Raw historical descMetadata.xml as of a given OCFL version. Same content
  # sensitivity as the public head /mods (it's the descriptive metadata
  # itself, not the attribution), so it rides the resource read floor.
  # Unknown version / absent MODS → 404.
  def mods_version
    authorize! :read, Resource
    xml = MODSVersionHistory.fetch_xml(resource: Resource.find(params[:id]), version_id: params[:version_id])
    return head(:not_found) if xml.nil?

    render xml: xml
  end

  # Batch resolver. Given a list of NOIDs, return a lightweight digest per
  # resolvable resource in a single request, so a caller resolving a set of
  # ids no longer fans out to one find per id. Mirrors #show's class-level
  # read floor (Atlas grants :read on every resource to any authenticated
  # principal). Unknown/unresolvable ids are dropped silently; tombstoned
  # resources are kept but flagged, so callers can render a placeholder rather
  # than blow up. Resolution is a single index-backed query
  # (FindManyByAlternateIdentifiers) — both the N HTTP round-trips and the N
  # per-id DB lookups collapse to one. Resolves alternate ids (NOIDs) only;
  # raw Valkyrie ids are not a supported input here.
  def find_many
    authorize! :read, Resource
    ids = Array(params[:ids]).map(&:to_s).uniq
    resources = Atlas.query.custom_queries.find_many_by_alternate_identifiers(alternate_identifiers: ids)
    @resources = resources.map(&:decorate)
  end
end
