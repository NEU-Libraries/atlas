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
    file_set = FileSet.find(params[:id])
  end

  def destroy
    # TODO: restrict to admin user
    Atlas.persister.delete(resource: FileSet.find(params[:id]))
  end
end
