# frozen_string_literal: true

# rubocop:disable Metrics/ClassLength
# Over the class-length bar because this is where the type-agnostic surface
# lives: seven reads and seven writes that used to be one action each on three
# typed controllers. Splitting reads from writes would put one resolution rule
# in two places, which is the drift this endpoint family exists to remove.
class ResourcesController < ApplicationController
  include CachedResponses
  include Auditable
  include DelegateUris
  include Reparentable
  include StaleObjectRetry

  # The types the generic MODS reads and every generic write answer for, each
  # with the ivar its own jbuilder partials read. `/resources/:id` resolves any
  # type, so THIS is the gate: a type absent here falls through to 404.
  TYPED_IVARS = {
    Work       => '@work',
    Collection => '@collection',
    Community  => '@community'
  }.freeze

  # Tombstone and restore also answer for a FileSet, so a caption or other
  # attached file can be withdrawn reversibly. Every other generic write stays
  # on TYPED_IVARS. See docs/resource-graph.md.
  LIFECYCLE_IVARS = TYPED_IVARS.merge(FileSet => '@file_set').freeze

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

  # Gated by :read_versions, as File versions are, rather than the resource's
  # own read gate, because the descriptors carry audit-derived attribution. The
  # verb is granted per type, so it is checked against the resolved class. An
  # empty array rather than a 404, mirroring /history's "no events" shape.
  def mods_versions
    @resource_id = params[:id]
    resource = Resource.find(@resource_id)
    authorize! :read_versions, resource&.class || Resource
    @versions = MODSVersionHistory.descriptors(resource: resource)
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
    return head(:not_found) unless resource && TYPED_IVARS.key?(resource.class) && resource.mods

    render_typed(resource, 'mods')
  end

  # PUT, not PATCH: the caller assembles the whole MODS document and this
  # replaces it, which is why descriptive merge logic lives in the client. See
  # docs/mods.md.
  #
  # A type that holds no MODS answers 404 here exactly as it does on the GET --
  # one answer per path, whichever verb asks.
  def put_mods
    resource = Resource.find(params.expect(:id))
    authorize! :update, resource || Resource
    return head(:not_found) unless resource && TYPED_IVARS.key?(resource.class)
    return head(:unprocessable_content) if params[:binary].blank?

    resource.mods_xml = File.read(uploaded_path(params[:binary]))
    saved = Atlas.persister.save(resource: resource)
    audit!(resource: saved, action: 'update', change_type: 'metadata', payload: mods_audit_payload)
    render_typed(saved, 'show')
  end

  # PATCH, and the verb is honoured per key: an omitted key keeps its stored
  # value, an explicitly empty one clears it. Permissions#permissions= owns
  # that rule. So changing one slot needs no read-the-envelope round trip.
  def update_permissions
    resource = Resource.find(params.expect(:id))
    authorize! :update, resource || Resource
    return head(:not_found) unless resource && TYPED_IVARS.key?(resource.class)

    render_typed(audited_permissions_update(resource, params[:permissions]), 'show')
  end

  def update_thumbnails
    resource = nil
    with_stale_object_retry do
      resource = Resource.find(params.expect(:id))
      authorize! :update_thumbnails, resource || Resource
      return head(:not_found) unless resource && TYPED_IVARS.key?(resource.class)

      apply_thumbnail_uris(resource_id: resource.id)
    end

    render_typed(Resource.find(resource.id), 'show')
  end

  # Two-sided authorization -- :reparent on the moved node AND on the
  # destination -- lives in Reparentable, which every type shared already.
  def update_parent
    resource = Resource.find(params.expect(:id))
    authorize! :reparent, resource || Resource
    return head(:not_found) unless resource && TYPED_IVARS.key?(resource.class)

    reparent_resolved(resource)
    render_typed(Resource.find(resource.id), 'show')
  end

  def tombstone
    resource = Resource.find(params.expect(:id))
    authorize! :tombstone, resource || Resource
    return head(:not_found) unless resource && LIFECYCLE_IVARS.key?(resource.class)

    reason  = params[:reason].presence
    refusal = tombstone_refusal(resource, reason)
    return render(json: refusal, status: :unprocessable_content) if refusal

    resource.tombstone(by: @current_user&.nuid, reason: reason)
    saved = save_lifecycle(resource)
    audit_lifecycle!(saved, 'tombstone', reason ? { reason: reason } : {})
    render_typed(saved, 'show')
  end

  def restore
    resource = Resource.find(params.expect(:id))
    authorize! :restore, resource || Resource
    return head(:not_found) unless resource && LIFECYCLE_IVARS.key?(resource.class)

    refusal = restore_refusal(resource)
    return render(json: refusal, status: :unprocessable_content) if refusal

    resource.restore
    saved = save_lifecycle(resource)
    audit_lifecycle!(saved, 'restore')
    render_typed(saved, 'show')
  end

  # Irreversible. Removes the resource's metadata, its members, and the OCFL
  # objects holding the preserved bytes. #tombstone is the withdrawal path --
  # that one keeps everything and can be undone.
  def destroy
    resource = Resource.find(params.expect(:id))
    authorize! :destroy, resource || Resource
    return head(:not_found) unless resource && TYPED_IVARS.key?(resource.class)

    # Ahead of has_children, so the answer cannot reveal whether a root is empty.
    if resource.top_level_community?
      refusal = { error: 'cannot destroy a top-level community', code: 'top_level_community' }
      return render(json: refusal, status: :unprocessable_content)
    end

    # Refuses while any container or Work is still a member, and -- unlike
    # tombstone -- refuses a member that is merely tombstoned: a purge cannot
    # be undone, so a member left behind is orphaned for good. An operator
    # empties the tree leaf-first instead. Uniform across types, because
    # filtered_children counts only those three: a Work's FileSets and Blobs
    # never block it and are cascaded into.
    if resource.filtered_children.any?
      message = "cannot destroy a #{resource.class.name.downcase} that still has members"
      return render(json: { error: message, code: 'has_children' }, status: :unprocessable_content)
    end

    ResourcePurger.call(resource: resource, actor_nuid: @current_user&.nuid,
                        on_behalf_of_nuid: @on_behalf_of)
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

  private

    # Renders the SAME per-type view the typed routes render, so a generic
    # write answers in the shape a typed find already parses and there is no
    # second representation of a type to drift.
    def render_typed(resource, view)
      instance_variable_set(LIFECYCLE_IVARS.fetch(resource.class), resource.decorate)
      render template: "#{resource.class.name.tableize}/#{view}"
    end

    # A top-level Community is refused first, so the answer cannot reveal
    # whether a root is empty. Otherwise refuses while the resource still holds
    # a live container or Work, so a withdrawal can never orphan a readable
    # descendant: `live_children?` counts only those three, so a Work holding
    # FileSets and Blobs always passes and they ride along.
    def tombstone_refusal(resource, reason)
      if resource.top_level_community?
        { error: 'cannot tombstone a top-level community', code: 'top_level_community' }
      elsif resource.live_children?
        { error: "cannot tombstone a non-empty #{resource.class.name.downcase}", code: 'has_live_children' }
      elsif reason && Resource::TOMBSTONE_REASONS.exclude?(reason)
        { error: 'reason is not one of the policy removal notes', code: 'invalid_reason' }
      end
    end

    # The mirror of `tombstone_refusal`: restoring under a withdrawn parent
    # would make the resource discoverable inside it, so restores run
    # root-first. A top-level Community has no parent and always passes.
    def restore_refusal(resource)
      return unless resource.parent&.tombstoned

      { error: 'restore the parent first', code: 'tombstoned_parent' }
    end

    # The envelope carries the withdrawal, so a rebuild from disk keeps it. A
    # derivative FileSet has no OCFL object of its own, and this must not
    # create one.
    def save_lifecycle(resource)
      saved = Atlas.persister.save(resource: resource)
      saved.write_preservation_envelope! unless saved.is_a?(FileSet) && !Classification.preserved?(saved.type)
      saved
    end

    # AuditEvent admits no FileSet, so a FileSet's event hangs off its Work as
    # a file event, the way BlobsController records one.
    def audit_lifecycle!(resource, action, payload = {})
      unless resource.is_a?(FileSet)
        return audit!(resource: resource, action: action, change_type: 'lifecycle',
                      payload: payload)
      end

      work = resource.parent
      return unless work.is_a?(Work)

      audit!(resource: work, action: action, change_type: 'file', payload: payload.merge(file_set_noid: resource.noid))
    end

    # The multipart upload arrives as a Rack or ActionDispatch upload
    # depending on the client, and only one of the two exposes #tempfile.
    def uploaded_path(file)
      file.tempfile.path.presence || file.path
    end
end
# rubocop:enable Metrics/ClassLength
