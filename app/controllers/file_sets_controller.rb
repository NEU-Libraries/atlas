# frozen_string_literal: true

# File Sets
class FileSetsController < ApplicationController
  include LazyPagination
  include IdempotentCreate
  include LeafWriteTarget
  include DelegateUris
  include StaleObjectRetry

  # The unfiltered roll of every FileSet. :index_all is admin-only (via the
  # manage :all wildcard) for the same reason as WorksController#index — a
  # paginated list cannot honour the per-resource read gate row by row.
  def index
    authorize! :index_all, FileSet
    @pagination, @file_sets = paginate_model(FileSet)
  end

  def show
    @file_set = FileSet.find(params.expect(:id))
    authorize! :read, @file_set || FileSet
    return head(:not_found) if @file_set.nil?

    refuse_tombstoned!(@file_set)
    render :show, status: (@file_set.tombstone_source ? :gone : :ok)
  end

  def mets
    @file_set = FileSet.find(params.expect(:id))
    authorize! :read, @file_set || FileSet
    refuse_tombstoned!(@file_set) if @file_set

    head(:not_found) if @file_set.nil? ||
                        Classification.metadata?(@file_set.type) ||
                        @file_set.mets.nil?
  end

  def create
    work = authorized_leaf_target(params[:work_id])

    if (record = find_idempotency_record(FileSet))
      @file_set = FileSet.find(record.resource_noid)
      return render_idempotent_resource(@file_set)
    end
    return head(:not_found) if work.nil?

    refuse_tombstoned!(work)

    @file_set = FileSetCreator.call(
      work_id:        work.noid,
      classification: Classification.find(
        params.expect(:classification)
      ),
      # Explicit cast: Valkyrie::Types::Integer is strict, and a form-encoded
      # "3" would raise where a JSON-body 3 passes.
      position:       params[:position].presence&.to_i
    )
    record_idempotency_key!(@file_set.noid, FileSet)
  end

  # Attach a binary as a Blob appended to an existing FileSet — the ordered/
  # classified-slot attach the migration uses after POST /file_sets cuts the
  # slot. Idempotent on the Idempotency-Key header (same semantics as create:
  # a replay returns the FileSet with its already-attached Blob, no recopy),
  # carries through the v1 original_filename, and honors verify-on-ingest via
  # expected_digest. Unknown id → 404.
  def update
    file_set = FileSet.find(params.expect(:id))
    authorize! :update, file_set || FileSet

    record = find_idempotency_record(FileSet)
    return render_idempotent_resource(@file_set = FileSet.find(record.resource_noid), view: :update) if record
    return head(:not_found) if file_set.nil?

    refuse_tombstoned!(file_set)

    BlobCreator.call(
      path:              uploaded_path(params[:binary]),
      file_set_id:       file_set.id,
      original_filename: params[:original_filename],
      expected_digest:   params[:expected_digest]
    )
    @file_set = FileSet.find(file_set.id)
    record_idempotency_key!(@file_set.noid, FileSet)
  end

  # Persist the per-page IIIF image-service pointer (Role.service_file) —
  # the Cantaloupe base URI for this page's JP2, which manifest assembly
  # reads back through GET /works/:id/file_sets. Upsert semantics via
  # DelegateUpdater: re-PATCHing a URI never mints a duplicate Delegate.
  def update_iiif_service
    with_stale_object_retry do
      @file_set = FileSet.find(params.expect(:id))
      authorize! :update_iiif_service, @file_set || FileSet
      return head(:not_found) if @file_set.nil?

      refuse_tombstoned!(@file_set)

      apply_iiif_service_uri(resource_id: @file_set.id)
    end

    @file_set = FileSet.find(params.expect(:id))
    render :show
  end

  # Irreversible. Removes the FileSet, its Blobs, and the preserved bytes.
  def destroy
    authorize! :destroy, FileSet
    file_set = FileSet.find(params.expect(:id))
    return head(:not_found) if file_set.nil?

    parent = file_set.parent
    ResourcePurger.call(resource: file_set)
    return rebuild_parent_mets(parent) if file_set.page?

    # A derivative FileSet writes no storage, so nothing else reindexes the
    # Work, whose doc rolls up its downloadable files.
    Atlas.reindex(parent) if parent.is_a?(Work)
  end

  private

    # The multipart upload arrives as a Rack or ActionDispatch upload
    # depending on the client, and only one of the two exposes #tempfile.
    def uploaded_path(file)
      file.tempfile.path.presence || file.path
    end

    # Eager-after-finalize (mirrors FileSetCreator): removing a page from a
    # completed Work re-cuts the preserved structMap so it never goes stale;
    # in-progress Works wait for POST /works/:id/complete.
    def rebuild_parent_mets(parent)
      return unless parent.is_a?(Work) && parent.in_progress == false

      parent = WorkMETSRebuilder.call(work: parent)
      # Page set shrank — re-project the Work's "Content" classification facet
      # (see FileSetCreator#reproject_classification). Solr-only, no lock bump.
      Atlas.reindex(parent)
    end
end
