# frozen_string_literal: true

# Reads `?page=` the way the search-backed lists do: a page below 1, or one
# that is not a number, is page 1. Left to itself, pagy raises on either, and
# the client sees a 500. Include it after Pagy::Backend, whose pagy_get_vars it
# wraps.
module PageParam
  def pagy_get_vars(collection, vars)
    vars[:page] ||= [params[:page].to_i, 1].max
    super
  end
end
