# frozen_string_literal: true

# The request side of the three scoped search actions. ScopedSearch checks the
# values, so f is handed over unpermitted: it is read field by field against
# the allowlist and never mass-assigned. See docs/search.md.
module ScopedSearchParams
  extend ActiveSupport::Concern

  included do
    rescue_from ScopedSearch::Invalid do |exception|
      render_error(:bad_request, exception.message)
    end
  end

  private

    def scoped_search
      ScopedSearch.new(query: params[:q], filters: params[:f], facets: params[:facet],
                       facet_limit: params[:facet_limit], sort: params[:sort])
    end

    def render_scoped_search(result)
      @works      = result.digests
      @pagination = result.pagination
      @facets     = result.facets
      render 'scoped_searches/search'
    end
end
