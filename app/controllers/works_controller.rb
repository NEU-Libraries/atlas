# frozen_string_literal: true

# Works
# rubocop:disable Metrics/ClassLength
# Slightly over the class-length bar because of the depositor-resolution
# helpers (proxy_uploader_nuid, depositor_nuid, parent_collection_for_depositor).
# Extracting them to a separate object would overweight the indirection vs.
# the work they do.
class WorksController < ApplicationController
  include LazyPagination
  include IdempotentCreate
  include DelegateUris
  include StaleObjectRetry
  include Reparentable
  include LinkedMembers
  include Auditable

  def index
    authorize! :read, Work
    @pagination, @works = paginate_model(Work, filters: index_filters)
  end

  def show
    authorize! :read, Work
    @work = Work.find(params[:id])&.decorate
    return head(:not_found) if @work.nil?

    render :show, status: (@work.tombstoned ? :gone : :ok)
  end

  def create
    authorize! :create, Work

    if (record = find_idempotency_record(Work))
      @work = Work.find(record.resource_noid)&.decorate
      return render_idempotent_resource(@work)
    end

    # TODO: XML
    @work = WorkCreator.call(
      parent_id:         params[:collection_id],
      proxy_uploader:    proxy_uploader_nuid,
      depositor:         depositor_nuid,
      actor_nuid:        @current_user&.nuid,
      on_behalf_of_nuid: @on_behalf_of
    )
    record_idempotency_key!(@work.noid, Work)
  end

  def mods
    authorize! :read, Work
    work = Work.find(params[:id])
    return head(:not_found) if work.nil? || work.mods.nil?

    @work = work.decorate
  end

  # Work-level METS (physical structMap — the preservation record of page
  # order). Built at /complete; 404 until then.
  def mets
    authorize! :read, Work
    work = Work.find(params[:id])
    return head(:not_found) if work.nil? || work.mets.nil?

    @work = work
  end

  def assets
    authorize! :read, Work
    @work = Work.find(params[:id])
    @assets = @work.children
                   .reject { |fs| Classification.metadata?(fs.type) }
                   .flat_map { |fs| Atlas.query.find_members(resource: fs).to_a }
                   .select   { |m| Role.downloadable?(m.use) }
  end

  # Sibling of #assets that preserves FileSet grouping and order — the read
  # a IIIF manifest assembler needs. #assets flattens; this returns one
  # entry per page-bearing FileSet, position ASC.
  def file_sets
    authorize! :read, Work
    @work = Work.find(params[:id])
    return head(:not_found) if @work.nil?

    @pages = @work.page_file_sets.map { |fs| [fs, page_assets(fs)] }
  end

  def update
    @work = Work.find(params[:id])
    authorize! :update, @work

    if params[:binary].present?
      binary_update
    elsif params[:metadata].present?
      metadata_update
    end
  end

  def update_thumbnails
    with_stale_object_retry do
      @work = Work.find(params[:id])
      authorize! :update_thumbnails, @work
      return head(:not_found) if @work.nil?

      apply_thumbnail_uris(resource_id: @work.id)
    end

    @work = Work.find(@work.id).decorate
    render :show
  end

  def update_image_derivatives
    with_stale_object_retry do
      @work = Work.find(params[:id])
      authorize! :update_image_derivatives, @work
      return head(:not_found) if @work.nil?

      apply_image_derivative_uris(resource_id: @work.id)
    end

    @work = Work.find(@work.id).decorate
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
      @work = Work.find(params[:id])
      authorize! :update_full_text, @work
      return head(:not_found) if @work.nil?

      @work.full_text = params[:text].to_s
      @work = Atlas.persister.save(resource: @work)
    end

    @work = Work.find(@work.id).decorate
    render :show
  end

  def destroy
    @work = Work.find(params[:id])
    authorize! :destroy, @work
    Atlas.persister.delete(resource: @work)
  end

  def tombstone
    @work = Work.find(params[:id])
    authorize! :tombstone, @work
    @work.tombstone(by: @current_user&.nuid)
    @work = Atlas.persister.save(resource: @work).decorate
    audit!(resource: @work, action: 'tombstone', change_type: 'lifecycle')
  end

  def restore
    @work = Work.find(params[:id])
    authorize! :restore, @work
    @work.restore
    @work = Atlas.persister.save(resource: @work).decorate
    audit!(resource: @work, action: 'restore', change_type: 'lifecycle')
  end

  def complete
    with_stale_object_retry do
      @work = Work.find(params[:id])
      authorize! :complete, @work
      return head(:not_found) if @work.nil?

      @work.in_progress = false
      @work = Atlas.persister.save(resource: @work).decorate
    end
    # Finalize-time build of the Work-level METS structMap (the
    # preservation record of page order). Unreached on a stale-object
    # 409 — retry exhaustion re-raises out of the block above.
    WorkMETSRebuilder.call(work: @work)
    audit!(resource: @work, action: 'complete', change_type: 'lifecycle')
  end

  # Move a Work to a different Collection. Trivial sibling of the collection/
  # community re-parent: a Work has no descendants and carries no ancestry
  # field, so there is no cascade — only its own a_member_of changes.
  def update_parent
    reparent(Work)
  end

  private

    # A page's downloadable assets: its own member Blobs plus the members of
    # any nested :derivative FileSet (per-page IIIF Delegates land there via
    # DelegateCreator(resource_id: <page FileSet>)). The page's METS Blob is
    # excluded by Role.downloadable?.
    def page_assets(file_set)
      file_set.children
              .flat_map { |c| c.is_a?(FileSet) ? Atlas.query.find_members(resource: c).to_a : [c] }
              .select { |m| Role.downloadable?(m.use) }
    end

    def index_filters
      return {} unless params.key?(:in_progress)

      { in_progress: ActiveModel::Type::Boolean.new.cast(params[:in_progress]) }
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
    def depositor_nuid
      return params[:depositor] if params[:depositor].present?
      return @on_behalf_of      if @on_behalf_of.present?

      collection = parent_collection_for_depositor
      return collection.depositor if collection&.depositor.present?

      proxy_uploader_nuid
    end

    def parent_collection_for_depositor
      return nil if params[:collection_id].blank?

      Collection.find(params[:collection_id])
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
