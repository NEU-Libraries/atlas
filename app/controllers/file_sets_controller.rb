# frozen_string_literal: true

# File Sets
class FileSetsController < ApplicationController
  include LazyPagination
  include IdempotentCreate

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

  def update
    authorize! :update, FileSet
    # Naive first implementation - expect a binary POST
    # and just add it to the existing file set
    # TODO: pass through original filename and label enumeration
    file = params[:binary]
    BlobCreator.call(
      path:        (file.tempfile.path.presence || file.path),
      file_set_id: params[:id]
    )
    @file_set = FileSet.find(params[:id])
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
