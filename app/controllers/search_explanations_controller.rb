# frozen_string_literal: true

# How the catalog search scores one Work, Collection or Community for some
# words, for debugging search from an API client. Admins and delegated admins
# only. See docs/search.md.
class SearchExplanationsController < ApplicationController
  include IndexReadGate

  def show
    resource = Resource.find(params.expect(:id))
    authorize_index_read!(resource)
    return head(:not_found) unless SearchExplanationQuery::TYPES.include?(resource.class.name)
    # A blank query browses, and every document scores the same.
    return render_error(:bad_request, 'q is required') if params[:q].blank?

    @explanation = SearchExplanationQuery.call(noid: resource.noid, query: params[:q])
  rescue SearchExplanationQuery::NotIndexed
    render_error(:not_found, 'not_indexed')
  end
end
