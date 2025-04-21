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
    @work = WorkCreator.call(parent_id: params[:collection_id])
  end

  def mods
    @work = Work.find(params[:id]).decorate
  end

  def update
    @work = Work.find(params[:id])

    if params[:binary].present?
      binary_update
    elsif params[:metadata].present?
      metadata_update
    end
  end

  def destroy
    # TODO: restrict to admin user
    Atlas.persister.delete(resource: Work.find(params[:id]))
  end

  private

    def binary_update
      # curl -F 'id=qrfj8zz' -F 'binary=@test.xml' http://localhost:3000/works/
      file = params[:binary]
      path = file.tempfile.path.presence || file.path
      @work.mods_xml = File.read(path)
      @work = Atlas.persister.save(resource: @work)
    end

    def metadata_update
      # allow for custom noid for testing purposes
      if Rails.env.test?
        @work.alternate_ids = params[:metadata]['noid'] if params[:metadata]['noid'].present?
      end
      @work.plain_title = params[:metadata]['title'] if params[:metadata]['title'].present?
      @work.plain_description = params[:metadata]['description'] if params[:metadata]['description'].present?
      @work.safe_thumbnail = params[:metadata]['thumbnail'] if params[:metadata]['thumbnail'].present?
      # permissions
      @work.permissions = params[:metadata]['permissions'] if params[:metadata]['permissions'].present?
      @work = Atlas.persister.save(resource: @work)
    end
end
