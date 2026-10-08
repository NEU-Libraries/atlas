# frozen_string_literal: true

# A Work's Darwin Core record: the read, the full-document write, the
# withdrawal and the version history. See docs/metadata-records.md.
#
# Every path answers 404 for a resource that is not a Work, whichever verb
# asks, because only a Work holds this record.
class DarwinCoreController < ApplicationController
  include Auditable
  include CachedResponses

  # The same gate as /works/:id/mods: whoever may read the Work may read its
  # Darwin Core.
  def show
    work = Work.find(params.expect(:id))
    authorize! :read, work || Work
    return head(:not_found) unless work&.darwin_core?

    cached_render(format_scope('works.dwc'), work) do
      @work = work
      respond_to do |format|
        format.json { render :show }
        format.xml  { render xml: work.darwin_core_xml }
      end
    end
  end

  # PUT, not PATCH: the caller sends the whole document and this replaces it.
  def update
    work = find_work
    authorize! :update, work || Work
    return head(:not_found) if work.nil?
    return head(:unprocessable_content) if params[:binary].blank?

    work.darwin_core_xml = File.read(uploaded_path(params[:binary]))
    audit!(resource: work, action: 'update', change_type: 'metadata', payload: audit_payload)
    @work = work
    render :show
  end

  # Withdraws rather than purges, so the bytes and the version history stay
  # and a later PUT brings the record back.
  def destroy
    work = find_work
    authorize! :update, work || Work
    return head(:not_found) unless work&.darwin_core?

    work.withdraw_darwin_core!(by: @current_user&.nuid)
    audit!(resource: work, action: 'tombstone', change_type: 'metadata', payload: audit_payload)
    head :no_content
  end

  # Gated by :read_versions, as /mods/versions is, because the descriptors
  # carry audit-derived attribution.
  def versions
    @resource_id = params[:id]
    work = find_work
    authorize! :read_versions, Work
    @versions = work ? DarwinCoreVersionHistory.descriptors(resource: work) : []
    render 'resources/mods_versions'
  end

  # The record itself rather than its attribution, so this rides the Work's
  # read gate.
  def version
    work = find_work
    authorize! :read, work || Work
    xml = work && DarwinCoreVersionHistory.fetch_xml(resource: work, version_id: params[:version_id])
    return head(:not_found) if xml.nil?

    render xml: xml
  end

  private

    # Resolves any NOID, then keeps only a Work, so a Collection's id answers
    # 404 here rather than reaching the Work-only concern.
    def find_work
      resource = Resource.find(params.expect(:id))
      resource if resource.is_a?(Work)
    end

    def audit_payload
      metadata_audit_payload(MetadataRecords::DarwinCore::SOURCE)
    end

    def uploaded_path(file)
      file.tempfile.path.presence || file.path
    end
end
