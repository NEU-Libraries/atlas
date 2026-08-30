# frozen_string_literal: true

# Works
# rubocop:disable Metrics/ClassLength
# Slightly over the class-length bar because of the depositor-resolution
# helpers (proxy_uploader_nuid, depositor_nuid). Extracting them to a separate
# object would overweight the indirection vs. the work they do.
class WorksController < ApplicationController
  include LazyPagination
  include IdempotentCreate
  include DelegateUris
  include StaleObjectRetry
  include Reparentable
  include LinkedMembers
  include WorkAssociations
  include Auditable
  include ParentScopedCreate

  # The operator monitoring filters on GET /works, each an exact match on a
  # Work lifecycle flag. An absent param means "no filtering" on that flag, so
  # ?in_progress=false stays distinguishable from omitting it; supplying both
  # narrows to the Works that satisfy each.
  INDEX_FILTER_FLAGS = %i[in_progress incomplete].freeze

  # The unfiltered roll of every Work, operator monitoring only (see
  # INDEX_FILTER_FLAGS). :index_all is granted to nobody but :admin, via the
  # manage :all wildcard — a paginated list cannot honour the per-resource read
  # gate without resolving the ACL of every row, and no caller needs it to.
  # Callers wanting a scoped list use /resources/:id/descendant_works, which is
  # gated in Solr.
  def index
    authorize! :index_all, Work
    @pagination, @works = paginate_model(Work, filters: index_filters)
    MODSPreloader.call(resources: @works)
  end

  def show
    work = find_work(params[:id])
    authorize! :read, work || Work
    return head(:not_found) if work.nil?

    @work = work.decorate

    render :show, status: (@work.tombstoned ? :gone : :ok)
  end

  # A Work always has a parent Collection, so a blank or unresolvable
  # collection_id is a 404. The container check runs only on the branch that
  # actually creates: a replay writes nothing and can only return a resource
  # this same caller already created (keys are scoped per user), so making it
  # depend on the parent still being there would add a failure mode to the
  # retry path bulk deposit relies on.
  def create
    authorize! :create, Work

    if (record = find_idempotency_record(Work))
      @work = Work.find(record.resource_noid)&.decorate
      return render_idempotent_resource(@work)
    end

    parent = authorized_create_parent(params[:collection_id])
    return head(:not_found) if parent.nil?

    # TODO: XML
    @work = WorkCreator.call(
      parent_id:         parent.noid,
      proxy_uploader:    proxy_uploader_nuid,
      depositor:         depositor_nuid(parent),
      actor_nuid:        @current_user&.nuid,
      on_behalf_of_nuid: @on_behalf_of
    )
    record_idempotency_key!(@work.noid, Work)
  end

  def mods
    work = find_work(params[:id])
    authorize! :read, work || Work
    return head(:not_found) if work.nil? || work.mods.nil?

    @work = work.decorate
  end

  # Work-level METS (physical structMap — the preservation record of page
  # order). Built at /complete; 404 until then.
  def mets
    work = find_work(params[:id])
    authorize! :read, work || Work
    return head(:not_found) if work.nil? || work.mets.nil?

    @work = work
  end

  def assets
    @work = find_work(params[:id])
    authorize! :read, @work || Work
    return head(:not_found) if @work.nil?

    # Pair each downloadable member with its FileSet's classification (fs.type)
    # so the flattened view can surface it per asset — the grouped #file_sets
    # read still has the FileSet in hand. Members come from one batched read
    # for every FileSet at once: a many-page Work would otherwise cost a query
    # per page.
    file_sets = @work.children.reject { |fs| Classification.metadata?(fs.type) }
    members   = Atlas.query.custom_queries.find_many_ordered_members(resources: file_sets)

    @assets = file_sets.flat_map do |fs|
      members.fetch(fs.id.to_s, [])
             .select { |m| Role.downloadable?(m.use) }
             .map    { |m| [m, fs.type] }
    end
  end

  # Sibling of #assets that preserves FileSet grouping and order — the read
  # a IIIF manifest assembler needs. #assets flattens; this returns one
  # entry per page-bearing FileSet, position ASC.
  def file_sets
    @work = find_work(params[:id])
    authorize! :read, @work || Work
    return head(:not_found) if @work.nil?

    pages  = @work.page_file_sets
    assets = PageAssetsQuery.call(file_sets: pages)
    @pages = pages.map { |fs| [fs, assets.fetch(fs.id.to_s, [])] }
  end

  def update
    @work = find_work(params[:id])
    authorize! :update, @work
    return head(:not_found) if @work.nil?

    if params[:binary].present?
      binary_update
    elsif params[:metadata].present?
      metadata_update
    end
  end

  def update_thumbnails
    with_stale_object_retry do
      @work = find_work(params[:id])
      authorize! :update_thumbnails, @work
      return head(:not_found) if @work.nil?

      apply_thumbnail_uris(resource_id: @work.id)
    end

    @work = Work.find(@work.id).decorate
    render :show
  end

  def update_image_derivatives
    with_stale_object_retry do
      @work = find_work(params[:id])
      authorize! :update_image_derivatives, @work
      return head(:not_found) if @work.nil?

      apply_image_derivative_uris(resource_id: @work.id)
    end

    @work = Work.find(@work.id).decorate
    render :show
  end

  # Replace the Work's per-tier derivative-visibility policy (see
  # TierVisibility) — which Grouper groups may fetch the small / medium / large
  # / service (deep-zoom) renditions. Unlike its Delegate-URI siblings this is a
  # rights edit, so it is NOT wrapped in with_stale_object_retry (silently
  # retrying would clobber a concurrent operator's different intent — the 409
  # surfaces instead) and it emits a `permissions` audit row. The updater
  # validates the two invariants (tier ⊆ Work, and visibility narrows with
  # resolution) and 422s on violation before persisting.
  def update_derivative_permissions
    @work = find_work(params[:id])
    authorize! :update_derivative_permissions, @work
    return head(:not_found) if @work.nil?

    before = @work.derivative_permissions_map
    @work  = DerivativePermissionsUpdater.call(work: @work, policy: derivative_permissions_body)
    audit!(resource: @work, action: 'update', change_type: 'permissions',
           payload: { before: before, after: @work.derivative_permissions_map, source: 'derivative_permissions' })
    @work = @work.decorate
    render :show
  end

  # Receive the Work-level aggregate of Cerberus-extracted document text and
  # store it as the Work's derived `full_text` attribute. FullTextIndexer then
  # projects it onto the Work's Solr doc (full_text_tesimv) for body-text search +
  # the "Full Text Match" snippet. Same "machine-set derived metadata" seam as
  # #update_thumbnails — re-sent on any re-ingest, never user-authored. Empty/
  # absent text clears the field. The response intentionally omits the text (a
  # long PDF is MBs) — it's write-only here, read back only through Solr.
  def update_full_text
    with_stale_object_retry do
      @work = find_work(params[:id])
      authorize! :update_full_text, @work
      return head(:not_found) if @work.nil?

      @work.full_text = params[:text].to_s
      @work = Atlas.persister.save(resource: @work)
    end

    @work = Work.find(@work.id).decorate
    render :show
  end

  # Irreversible. Removes the Work's metadata, its FileSets, their Blobs, and
  # the OCFL objects holding the preserved bytes. Use tombstone for the
  # withdrawal path — that one keeps everything and can be undone.
  def destroy
    @work = find_work(params[:id])
    authorize! :destroy, @work
    return head(:not_found) if @work.nil?

    ResourcePurger.call(resource: @work, actor_nuid: @current_user&.nuid,
                        on_behalf_of_nuid: @on_behalf_of)
  end

  def tombstone
    @work = find_work(params[:id])
    authorize! :tombstone, @work
    return head(:not_found) if @work.nil?

    @work.tombstone(by: @current_user&.nuid)
    @work = Atlas.persister.save(resource: @work).decorate
    audit!(resource: @work, action: 'tombstone', change_type: 'lifecycle')
  end

  def restore
    @work = find_work(params[:id])
    authorize! :restore, @work
    return head(:not_found) if @work.nil?

    @work.restore
    @work = Atlas.persister.save(resource: @work).decorate
    audit!(resource: @work, action: 'restore', change_type: 'lifecycle')
  end

  def complete
    with_stale_object_retry do
      @work = find_work(params[:id])
      authorize! :complete, @work
      return head(:not_found) if @work.nil?

      @work.in_progress = false
      @work = Atlas.persister.save(resource: @work).decorate
    end
    # Finalize-time build of the Work-level METS structMap (the
    # preservation record of page order). Unreached on a stale-object
    # 409 — retry exhaustion re-raises out of the block above.
    WorkMETSRebuilder.call(work: @work)
    # Mint the persistent identifier last, and reassign because the response
    # renders the handle. HandleMinter is best-effort: it reloads past the
    # METS write, skips a Work that already has a handle, and swallows a
    # handle-server outage — /complete cannot be allowed to fail on an
    # external service it does not need to have succeeded.
    @work = HandleMinter.call(work: @work).decorate
    audit!(resource: @work, action: 'complete', change_type: 'lifecycle')
  end

  # Flag a Work whose enrichment pipeline gave up (see Work#incomplete). The
  # reason is a machine token Atlas stores unvalidated; a blank or absent one
  # still sets the flag, because the caller is a job already on its own
  # failure path and a 422 here would fail that failure handler. Idempotent —
  # the last reason wins — so it is safe under the retry wrapper. No audit
  # row: this is machine-set derived state that a later successful run clears
  # by itself, like the thumbnail and full-text setters.
  def mark_incomplete
    with_stale_object_retry do
      @work = find_work(params[:id])
      authorize! :mark_incomplete, @work
      return head(:not_found) if @work.nil?

      @work.incomplete        = true
      @work.incomplete_reason = params[:reason].presence
      @work = Atlas.persister.save(resource: @work).decorate
    end
    render :show
  end

  # Clear the flag and its reason together — the repair half of the pair,
  # called when a later run of the same job succeeds.
  def clear_incomplete
    with_stale_object_retry do
      @work = find_work(params[:id])
      authorize! :clear_incomplete, @work
      return head(:not_found) if @work.nil?

      @work.incomplete        = false
      @work.incomplete_reason = nil
      @work = Atlas.persister.save(resource: @work).decorate
    end
    render :show
  end

  # Move a Work to a different Collection. Trivial sibling of the collection/
  # community re-parent: a Work has no descendants and carries no ancestry
  # field, so there is no cascade — only its own a_member_of changes.
  def update_parent
    reparent(Work)
  end

  private

    # Resolve :id to a Work, or nil if the id is absent OR names a resource of
    # another type. Valkyrie's `Work.find` is not type-scoped — it returns
    # whatever resource carries the id — so a hand-edited /works/<community-id>
    # would otherwise feed a non-Work into the Work serializer (which calls
    # Work-only methods like derivative_permissions_map) and 500. Collapsing a
    # wrong-type id to nil keeps the endpoint's type contract: it 404s exactly
    # like an unknown id, across the whole /works/:id surface.
    def find_work(id)
      work = Work.find(id)
      work if work.is_a?(Work)
    end

    # The submitted tier policy, read straight from the JSON body rather than
    # `params` — ParamsWrapper mirrors the body under a `work` key that would
    # otherwise look like an unknown tier. Reading raw keeps unknown tier keys
    # visible to the updater (so a typo is rejected, not silently dropped).
    def derivative_permissions_body
      JSON.parse(request.raw_post.presence || '{}')
    rescue JSON::ParserError
      {}
    end

    # A blank value counts as absent, not as "match works whose flag is nil".
    # `?in_progress=` is what a caller sends when it builds the query string
    # from an unset variable, and casting that empty string gives nil, which
    # matches no Work at all — an empty list reads as "nothing is stuck" and
    # would be a lie. `to_s` keeps a literal false readable as false.
    def index_filters
      INDEX_FILTER_FLAGS.each_with_object({}) do |flag, filters|
        next if params[flag].to_s.blank?

        filters[flag] = ActiveModel::Type::Boolean.new.cast(params[flag])
      end
    end

    # The hands-on-keyboard actor for this create. Under acting-as the
    # On-Behalf-Of header is present and there is NO hands-on-keyboard
    # stamp — the deposit reads as pure impersonation (proxy_uploader left
    # null, admin recorded only in the AuditEvent). Otherwise the
    # authenticated caller is the proxy_uploader. (The creator also nulls it
    # defensively to defeat parent-permission inheritance.)
    def proxy_uploader_nuid
      return nil if @on_behalf_of.present?

      @current_user&.nuid
    end

    # The intellectual owner. Resolution order:
    #   1. explicit form param (the in-band proxy radio supplies the
    #      parent collection's depositor; acting-as sends depositor = target).
    #   2. acting-as target (On-Behalf-Of) — the deposit is attributed to T.
    #   3. parent collection's default depositor (the anonymous-batch
    #      shape — points the collection at the :anonymous user and
    #      every Work inherits).
    #   4. proxy_uploader (self-deposit fallback).
    def depositor_nuid(parent)
      return params[:depositor] if params[:depositor].present?
      return @on_behalf_of      if @on_behalf_of.present?
      return parent.depositor   if parent&.depositor.present?

      proxy_uploader_nuid
    end

    def binary_update
      # curl -F 'id=qrfj8zz' -F 'binary=@test.xml' http://localhost:3000/works/
      file = params[:binary]
      path = file.tempfile.path.presence || file.path
      @work.mods_xml = File.read(path)
      @work = Atlas.persister.save(resource: @work)
      audit!(resource: @work, action: 'update', change_type: 'metadata', payload: { source: 'mods' })
    end

    def metadata_update
      @work = audited_metadata_update(@work)
    end
end
# rubocop:enable Metrics/ClassLength
