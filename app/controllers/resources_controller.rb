# frozen_string_literal: true

class ResourcesController < ApplicationController
  include CachedResponses

  # Renders the SAME per-type view the typed routes use, so there is no second
  # MODS representation to drift. A type absent here falls through to 404.
  TYPED_MODS_VIEWS = {
    Work       => ['@work',       'works/mods'],
    Collection => ['@collection', 'collections/mods'],
    Community  => ['@community',  'communities/mods']
  }.freeze

  def show
    resource = Resource.find(params.expect(:id))
    authorize! :read, resource || Resource
    return head(:not_found) if resource.nil?

    @resource = resource.decorate
    # Person has no resourceful route, so polymorphic redirect_to can't build
    # its path — send it to the NOID-keyed endpoint.
    return redirect_to(person_path(@resource.noid)) if @resource.is_a?(Person)
    # A Blob's typed route is /files/:id, so the polymorphic helper would be
    # blob_url, which no route defines.
    return redirect_to(file_path(@resource.noid)) if @resource.is_a?(Blob)

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

  # Gated on :read of the RESOURCE, not the class: the envelope names Grouper
  # groups and the depositor's NUID, so handing it to a caller who may not
  # read the resource discloses the rights of something they cannot see.
  def permissions
    resource = Resource.find(params.expect(:id))
    authorize! :read, resource || Resource
    return head(:not_found) if resource.nil?

    cached_render('resources.permissions', resource) do
      @resource = resource
      render :permissions
    end
  end

  # Admin-gated on :read, AuditEvent rather than the resource's own read gate,
  # because the descriptors carry audit-derived attribution. An empty array
  # rather than a 404, mirroring /history's "no events" shape.
  def mods_versions
    authorize! :read, AuditEvent
    @resource_id = params[:id]
    @versions = MODSVersionHistory.descriptors(resource: Resource.find(@resource_id))
  end

  # The descriptive metadata itself rather than the attribution, so this rides
  # the resource's own read gate and NOT the admin gate #mods_versions uses.
  def mods_version
    resource = Resource.find(params.expect(:id))
    authorize! :read, resource || Resource
    xml = MODSVersionHistory.fetch_xml(resource: resource, version_id: params[:version_id])
    return head(:not_found) if xml.nil?

    render xml: xml
  end

  # Gates on the RESOLVED RECORD, matching the typed per-record gate rather
  # than this controller's class-level floor, so a gated object's MODS is as
  # protected here as via /works/:id/mods.
  def mods
    resource = Resource.find(params.expect(:id))
    authorize! :read, resource || Resource
    return head(:not_found) unless resource && TYPED_MODS_VIEWS.key?(resource.class) && resource.mods

    ivar, template = TYPED_MODS_VIEWS[resource.class]
    instance_variable_set(ivar, resource.decorate)
    render template: template
  end

  # Batch resolver. The class check answers "may this principal use the
  # resolver at all"; the READ GATE IS PER ROW below, because the ids are
  # arbitrary caller input. Unresolvable ids drop silently; tombstoned
  # resources are kept but flagged. NOIDs only, not raw Valkyrie ids.
  def find_many
    authorize! :read, Resource
    ids = Array(params[:ids]).map(&:to_s).uniq
    resources = Atlas.query.custom_queries.find_many_by_alternate_identifiers(alternate_identifiers: ids)
    # Without this filter the endpoint is a batch bypass of the
    # single-resource read gate.
    @resources = readable(resources).map(&:decorate)
    # NOT optional: the digest renders a title and a thumbnail per row, each
    # its own read, so without batching the endpoint just moves the fan-out
    # from HTTP to Postgres.
    MODSPreloader.call(resources: @resources)
    ThumbnailPreloader.call(resources: @resources)
  end

  # The structural counterpart to /compilations/:id/contents, sharing its
  # digest shape and query engine. Only structural membership counts unless
  # ?include_linked=true.
  #
  # Gating is PER WORK inside the query, so a restricted Work never leaks via
  # the subtree, and ids are projected from Solr at every step -- nothing
  # materializes, even for a 10k-deep collection.
  def descendant_works
    resource = Resource.find(params.expect(:id))
    authorize! :read, resource || Resource
    return head(:not_found) if resource.nil?

    result = DescendantWorksQuery.call(
      resource: resource, user: @current_user,
      page: params[:page], per_page: params[:per_page],
      include_linked: ActiveModel::Type::Boolean.new.cast(params[:include_linked])
    )
    @works      = result.digests
    @pagination = result.pagination
  end

  # Solr ONLY: no Postgres write, no optimistic-lock bump, no lifecycle,
  # audit or minting. That is the point -- a resource finalized before an
  # indexer shipped must be re-projected WITHOUT abusing a lifecycle
  # transition. Idempotent.
  def reindex
    authorize! :reindex, Resource
    resource = Resource.find(params.expect(:id))
    return head(:not_found) if resource.nil?

    Atlas.index_adapter.persister.save(resource: resource)
    head :no_content
  end

  # The gather is a deliberate SUPERSET of the re-parent cascade: descendant
  # containers plus the Works beneath them, because a reindex refreshes
  # projections that live on Works and the container-only cascade never
  # touches those. Synchronous, matching Atlas's posture.
  def reindex_subtree
    authorize! :reindex, Resource
    resource = Resource.find(params.expect(:id))
    return head(:not_found) if resource.nil?

    count = SubtreeReindexer.call(resources: SubtreeResourcesQuery.call(resource))
    render json: { reindexed: count }
  end
end
