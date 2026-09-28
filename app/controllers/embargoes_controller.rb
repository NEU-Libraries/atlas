# frozen_string_literal: true

# POST /embargoes/release records the embargoes that have lapsed. The caller
# supplies the schedule; see EmbargoReleaseRecorder.
class EmbargoesController < ApplicationController
  def release
    authorize! :release, :embargo

    since = parse_since
    return render_error(:bad_request, 'since must be an ISO 8601 date') if since == :invalid

    @released = EmbargoReleaseRecorder.call(actor: @current_user, since: since,
                                            event_source: @current_user.system? ? 'job' : 'controller')
    render 'embargoes/release'
  end

  private

    def parse_since
      return nil if params[:since].blank?

      Date.iso8601(params[:since]).to_time(:utc)
    rescue Date::Error
      :invalid
    end
end
