# frozen_string_literal: true

# POST /fixity_checks records one result an external checker produced by
# re-hashing an OCFL object. See docs/fixity.md.
class FixityChecksController < ApplicationController
  def create
    authorize! :record, :fixity_check

    # NOT params: the router's own keys would ride along into the check.
    @check    = FixityCheck.new(request.request_parameters, recorded_by: @current_user&.nuid)
    @recorded = FixityCheckRecorder.call(check: @check)
    return head(:not_found) if @recorded.nil?

    # A replay of a line already in the log adds nothing, so it is not a create.
    render :create, status: @recorded[:appended] ? :created : :ok
  end

  def due
    authorize! :read_due, :fixity_check

    before = parse_before
    return render_error(:bad_request, 'checked_before must be an ISO 8601 timestamp') if before == :invalid

    @due = FixityDueQuery.call(limit: (params[:limit] || 100).to_i, before: before)
    render :due
  end

  private

    # Defaults to now, which lists every object; a sweep passes its own start.
    def parse_before
      return Time.current if params[:checked_before].blank?

      Time.iso8601(params[:checked_before])
    rescue ArgumentError
      :invalid
    end
end
