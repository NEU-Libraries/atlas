# frozen_string_literal: true

# File Sets
class FileSetsController < ApplicationController
  include LazyPagination
  include IdempotentCreate
  include DelegateUris
  include StaleObjectRetry

  def index
    authorize! :read, FileSet
    @pagination, @file_sets = paginate_model(FileSet)
  end

  def show
    authorize! :read, FileSet
    @file_set = FileSet.find(params[:id])
    return head(:not_found) if @file_set.nil?

    render :show, status: (@file_set.tombstoned ? :gone : :ok)
  end

  def mets
    authorize! :read, FileSet
    @file_set = FileSet.find(params[:id])
    return head(:not_found) if @file_set.nil?
    return head(:not_found) if Classification.metadata?(@file_set.type)
    return head(:not_found) if @file_set.mets.nil?
  end

  def create
    authorize! :create, FileSet

    if (record = find_idempotency_record(FileSet))
      @file_set = FileSet.find(record.resource_noid)
      return render_idempotent_resource(@file_set)
    end

    @file_set = FileSetCreator.call(
      work_id:        params[:work_id],
      classification: Classification.find(
        params[:classification]
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
  # expected_digest.
  def update
    authorize! :update, FileSet

    if (record = find_idempotency_record(FileSet))
      @file_set = FileSet.find(record.resource_noid)
      return render_idempotent_resource(@file_set, view: :update)
    end

    file = params[:binary]
    BlobCreator.call(
      path:              (file.tempfile.path.presence || file.path),
      file_set_id:       params[:id],
      original_filename: params[:original_filename],
      expected_digest:   params[:expected_digest]
    )
    @file_set = FileSet.find(params[:id])
    record_idempotency_key!(@file_set.noid, FileSet)
  end

  # Persist the per-page IIIF image-service pointer (Role.service_file) —
  # the Cantaloupe base URI for this page's JP2, which manifest assembly
  # reads back through GET /works/:id/file_sets. Upsert semantics via
  # DelegateUpdater: re-PATCHing a URI never mints a duplicate Delegate.
  def update_iiif_service
    authorize! :update_iiif_service, FileSet

    with_stale_object_retry do
      @file_set = FileSet.find(params[:id])
      return head(:not_found) if @file_set.nil?

      apply_iiif_service_uri(resource_id: @file_set.id)
    end

    @file_set = FileSet.find(params[:id])
    render :show
  end

  def destroy
    authorize! :destroy, FileSet
    file_set = FileSet.find(params[:id])
    parent = file_set.parent
    Atlas.persister.delete(resource: file_set)
    rebuild_parent_mets(parent, file_set)
  end

  private

    # Eager-after-finalize (mirrors FileSetCreator): removing a page from a
    # completed Work re-cuts the preserved structMap so it never goes stale;
    # in-progress Works wait for POST /works/:id/complete.
    def rebuild_parent_mets(parent, file_set)
      return unless file_set.page?
      return unless parent.is_a?(Work) && parent.in_progress == false

      WorkMETSRebuilder.call(work: parent)
    end
end
