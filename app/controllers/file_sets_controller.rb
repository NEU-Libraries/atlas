# frozen_string_literal: true

# File Sets
class FileSetsController < ApplicationController
  include LazyPagination
  include TombstoneAware
  tombstone_aware_for resource_class: FileSet, var: :file_set, decorate: false

  def index
    @pagination, @file_sets = paginate_model(FileSet)
  end

  def show
    # @file_set set by TombstoneAware before_action
  end

  def mets
    @file_set = FileSet.find(params[:id])
    return head(:not_found) if @file_set.nil?
    return head(:not_found) if Classification.metadata?(@file_set.type)
    return head(:not_found) if @file_set.mets.nil?
  end

  def create
    @file_set = FileSetCreator.call(
      work_id: params[:work_id],
      classification: Classification.find(
        params[:classification]
      )
    )
  end

  def update
    # Naive first implementation - expect a binary POST
    # and just add it to the existing file set
    # TODO: pass through original filename and label enumeration
    file = params[:binary]
    BlobCreator.call(
      path: (file.tempfile.path.presence || file.path),
      file_set_id: params[:id]
    )
    @file_set = FileSet.find(params[:id])
  end

  def destroy
    # TODO: restrict to admin user
    Atlas.persister.delete(resource: FileSet.find(params[:id]))
  end
end
