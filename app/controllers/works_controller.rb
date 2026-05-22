# frozen_string_literal: true

# Works
# rubocop:disable Metrics/ClassLength
# Five lines over the 120-line bar from the depositor-resolution helpers
# (proxy_uploader_nuid, depositor_nuid, parent_collection_for_depositor)
# added in piece 3. Extracting them to a separate object would overweight
# the indirection vs. the work they do.
class WorksController < ApplicationController
  include LazyPagination
  include IdempotentCreate
  include DelegateUris

  def index
    authorize! :read, Work
    @pagination, @works = paginate_model(Work, filters: index_filters)
  end

  def show
    authorize! :read, Work
    @work = Work.find(params[:id])&.decorate
    return head(:not_found) if @work.nil?

    render :show, status: (@work.tombstoned ? :gone : :ok)
  end

  def create
    authorize! :create, Work

    if (record = find_idempotency_record(Work))
      @work = Work.find(record.resource_noid)&.decorate
      return render_idempotent_resource(@work)
    end

    # TODO: XML
    @work = WorkCreator.call(
      parent_id:         params[:collection_id],
      proxy_uploader:    proxy_uploader_nuid,
      depositor:         depositor_nuid,
      actor_nuid:        @current_user&.nuid,
      on_behalf_of_nuid: @on_behalf_of
    )
    record_idempotency_key!(@work.noid, Work)
  end

  def mods
    authorize! :read, Work
    work = Work.find(params[:id])
    return head(:not_found) if work.nil? || work.mods.nil?

    @work = work.decorate
  end

  def assets
    authorize! :read, Work
    @work = Work.find(params[:id])
    @assets = @work.children
                   .reject { |fs| fs.type == Classification.descriptive_metadata.name }
                   .flat_map { |fs| Atlas.query.find_members(resource: fs).to_a }
                   .select   { |m| Role.downloadable?(m.use) }
  end

  def update
    @work = Work.find(params[:id])
    authorize! :update, @work

    if params[:binary].present?
      binary_update
    elsif params[:metadata].present?
      metadata_update
    end
  end

  def update_thumbnails
    @work = Work.find(params[:id])
    authorize! :update_thumbnails, @work
    return head(:not_found) if @work.nil?

    apply_thumbnail_uris(resource_id: @work.id)
    @work = Work.find(@work.id).decorate
    render :show
  end

  def update_image_derivatives
    @work = Work.find(params[:id])
    authorize! :update_image_derivatives, @work
    return head(:not_found) if @work.nil?

    apply_image_derivative_uris(resource_id: @work.id)
    @work = Work.find(@work.id).decorate
    render :show
  end

  def destroy
    @work = Work.find(params[:id])
    authorize! :destroy, @work
    Atlas.persister.delete(resource: @work)
  end

  def tombstone
    @work = Work.find(params[:id])
    authorize! :tombstone, @work
    @work.tombstone(by: @nuid)
    @work = Atlas.persister.save(resource: @work).decorate
  end

  def restore
    @work = Work.find(params[:id])
    authorize! :restore, @work
    @work.restore
    @work = Atlas.persister.save(resource: @work).decorate
  end

  def complete
    @work = Work.find(params[:id])
    authorize! :complete, @work
    return head(:not_found) if @work.nil?

    @work.in_progress = false
    @work = Atlas.persister.save(resource: @work).decorate
  end

  private

    def index_filters
      return {} unless params.key?(:in_progress)

      { in_progress: ActiveModel::Type::Boolean.new.cast(params[:in_progress]) }
    end

    # The hands-on-keyboard actor for this create. During acting-as
    # (piece 5) the On-Behalf-Of header populates @on_behalf_of and the
    # target NUID becomes the proxy_uploader; otherwise the authenticated
    # caller is the proxy_uploader.
    def proxy_uploader_nuid
      @on_behalf_of.presence || @current_user&.nuid
    end

    # The intellectual owner. Resolution order:
    #   1. explicit form param (the in-band proxy radio supplies the
    #      parent collection's depositor; piece 5 acting-as does not use
    #      this path).
    #   2. parent collection's default depositor (the anonymous-batch
    #      shape — points the collection at the :anonymous user and
    #      every Work inherits).
    #   3. proxy_uploader (self-deposit fallback).
    def depositor_nuid
      return params[:depositor] if params[:depositor].present?

      collection = parent_collection_for_depositor
      return collection.depositor if collection&.depositor.present?

      proxy_uploader_nuid
    end

    def parent_collection_for_depositor
      return nil if params[:collection_id].blank?

      Collection.find(params[:collection_id])
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
    end
end
# rubocop:enable Metrics/ClassLength
