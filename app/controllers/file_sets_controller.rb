# frozen_string_literal: true

# File Sets
class FileSetsController < ApplicationController
  include LazyPagination

  def index
    @pagination, @file_sets = paginate_model(FileSet)
  end

  def show
    @file_set = FileSet.find(params[:id])
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
    file = params[:binary]
    blob = BlobCreator.call(
      path: (file.tempfile.path.presence || file.path),
      file_set_id: params[:id]
    )
    file_set = FileSet.find(params[:id])
    file_set.member_ids += [blob.id]
    @file_set = Atlas.persister.save(resource: file_set)
  end

  def destroy
    # TODO: restrict to admin user
    Atlas.persister.delete(resource: FileSet.find(params[:id]))
  end
end
