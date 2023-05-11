# frozen_string_literal: true

# Works
class WorksController < ApplicationController
  include LazyPagination

  def index
    @pagination, @works = paginate_model(Work)
  end
  def show
    @work = Work.find(params[:id]).decorate
  end
  def create
    # TODO: XML
    work = WorkCreator.call()
  end
  def mods
    @work = Work.find(params[:id]).decorate
  end
  def update
    work = Work.find(params[:id])
    work.mods_xml = parse_xml
  end
  def destroy
    # TODO: restrict to admin user
    Atlas.persister.delete(resource: Work.find(params[:id]))
  end
end
