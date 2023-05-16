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
    # TODO: Needs work id
    # TODO: Needs classification
    file_set = FileSetCreator.call
  end

  def mods
    @file_set = FileSet.find(params[:id])
  end

  def update
    # Naive first implementation - expect a binary POST
    # and just add it to the existing file set
    file = params[:binary]
    blob = BlobCreator.call(
      work_id: nil,
      path: (file.tempfile.path.presence ||
             file.path),
      file_set_id: params[:id]
    )
    file_set = FileSet.find(params[:id])
    file_set.member_ids += [blob.id]
    Atlas.persister.save(resource: file_set)
  end

  def destroy
    # TODO: restrict to admin user
    Atlas.persister.delete(resource: FileSet.find(params[:id]))
  end
end
