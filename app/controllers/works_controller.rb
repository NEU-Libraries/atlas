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
    # TODO: Needs collection id
    work = WorkCreator.call
  end

  def mods
    @work = Work.find(params[:id]).decorate
  end

  def update
    # curl -F 'id=qrfj8zz' -F 'binary=@test.xml' http://localhost:3000/blobs/
    work = Work.find(params[:id])
    file = params[:binary]
    path = file.tempfile.path.presence || file.path
    work.mods_xml = File.read(path)
  end

  def destroy
    # TODO: restrict to admin user
    Atlas.persister.delete(resource: Work.find(params[:id]))
  end
end
