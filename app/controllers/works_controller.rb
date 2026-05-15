# frozen_string_literal: true

# Works
class WorksController < ApplicationController
  include LazyPagination
  include IdempotentCreate

  def index
    @pagination, @works = paginate_model(Work, filters: index_filters)
  end

  def show
    @work = Work.find(params[:id])&.decorate
    return head(:not_found) if @work.nil?

    render :show, status: (@work.tombstoned ? :gone : :ok)
  end

  def create
    if (record = find_idempotency_record(Work))
      @work = Work.find(record.resource_noid)&.decorate
      return render_idempotent_resource(@work)
    end

    # TODO: XML
    @work = WorkCreator.call(parent_id: params[:collection_id])
    record_idempotency_key!(@work.noid, Work)
  end

  def mods
    work = Work.find(params[:id])
    return head(:not_found) if work.nil? || work.mods.nil?

    @work = work.decorate
  end

  def assets
    @work = Work.find(params[:id])
    @assets = @work.children
                   .reject { |fs| fs.type == Classification.descriptive_metadata.name }
                   .flat_map { |fs| Atlas.query.find_members(resource: fs).to_a }
                   .select   { |m| Role.downloadable?(m.use) }
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

  def tombstone
    @work = Work.find(params[:id])
    @work.tombstone(by: @nuid)
    @work = Atlas.persister.save(resource: @work).decorate
  end

  def restore
    @work = Work.find(params[:id])
    @work.restore
    @work = Atlas.persister.save(resource: @work).decorate
  end

  def complete
    @work = Work.find(params[:id])
    return head(:not_found) if @work.nil?

    @work.in_progress = false
    @work = Atlas.persister.save(resource: @work).decorate
  end

  private

    def index_filters
      return {} unless params.key?(:in_progress)

      { in_progress: ActiveModel::Type::Boolean.new.cast(params[:in_progress]) }
    end

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
      # permissions
      @work.permissions = params[:metadata]['permissions'] if params[:metadata]['permissions'].present?
      @work = Atlas.persister.save(resource: @work)
      @work.write_preservation_envelope!
      # DelegateUpdater rotates @work's optimistic_lock_token via the
      # parent-reindex save, so it runs after the in-memory mutations
      # above have been persisted — otherwise the controller's @work
      # save loses to a StaleObjectError.
      if params[:metadata]['thumbnail'].present?
        DelegateUpdater.call(
          resource_id: @work.id,
          use:         Role.thumbnail_image.name,
          uri:         params[:metadata]['thumbnail']
        )
      end
    end
end
