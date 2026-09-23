# frozen_string_literal: true

# Keyword search over the catalog. Every principal but :anonymous may search;
# which documents each one sees is the query's read gate, not cancancan. See
# docs/search.md.
class SearchController < ApplicationController
  def index
    authorize! :read, :catalog

    result = SearchQuery.call(user: @current_user, query: params[:q], type: params[:type],
                              page: params[:page], per_page: params[:per_page])
    @results    = result.results
    @pagination = result.pagination
  rescue SearchQuery::UnknownType => e
    render_error(:bad_request, e.message)
  end
end
