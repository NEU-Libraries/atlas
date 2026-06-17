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

  # Re-project a single resource's Solr doc from its current Postgres/OCFL
  # state. Solr-only (Atlas.index_adapter) — no Postgres write, no
  # optimistic-lock bump, no lifecycle/audit/minting. This is the
  # purpose-built, side-effect-free reindex: when an indexer ships or changes
  # (e.g. ClassificationIndexer -> classification_ssim), a resource finalized
  # before it carries a stale/empty projection and must be re-indexed without
  # abusing a lifecycle transition (POST /works/:id/complete). :system-gated —
  # an operational action, never a user one. Idempotent. Unknown id -> 404.
  def reindex
    authorize! :reindex, Resource
    resource = Resource.find(params[:id])
    return head(:not_found) if resource.nil?

    Atlas.index_adapter.persister.save(resource: resource)
    head :no_content
  end

  # Re-project a resource AND its full descendant subtree. The gather is a
  # deliberate superset of the re-parent cascade: descendant containers
  # (Collection/Community, via ancestor_ids_ssim) PLUS the Works beneath them,
  # because a reindex refreshes any projection — including classification_ssim,
  # which lives on Works, which the container-only reparent cascade never
  # touches. Fed to the generic SubtreeReindexer (Solr-only, idempotent,
  # order-independent). Stays synchronous (Atlas's posture); for a
  # pathologically large subtree the caller (Cerberus) roots lower or drives it
  # in chunks. Unknown id -> 404. Returns the count re-projected.
  def reindex_subtree
    authorize! :reindex, Resource
    resource = Resource.find(params[:id])
    return head(:not_found) if resource.nil?

    count = SubtreeReindexer.call(resources: SubtreeResourcesQuery.call(resource))
    render json: { reindexed: count }
  end
end
