# frozen_string_literal: true

module LazyPagination
  include Pagy::Backend
  extend ActiveSupport::Concern

  # Caps caller-supplied per_page so a request can't ask for an unbounded page.
  MAX_PER_PAGE = 100

  def paginate_model(klass, filters: {}, per_page: nil)
    results = Atlas.query.find_all_of_model(model: klass)
    results = apply_filters(results, filters) if filters.present?
    pagy, items = pagy(results, count: results.count, **per_page_vars(per_page))
    pagination = pagy_metadata(pagy)
    [pagination, items]
  end

  # Paginate an already-resolved in-memory array (e.g. a batch-resolved set)
  # with no truncation: page size follows the array length, so the whole match
  # comes back in one page while keeping the uniform paginated response shape.
  # Shares the array-aware pagy_get_items override below.
  def paginate_array(array)
    array = Array(array)
    pagy, items = pagy(array, count: array.size, items: [array.size, 1].max)
    [pagy_metadata(pagy), items]
  end

  def pagy_get_items(lazy, pagy)
    lazy.drop(pagy.offset).first(pagy.items)
  end

  private

    # Map an optional caller per_page into pagy's :items var (clamped). Blank
    # leaves pagy on its configured default (Pagy::DEFAULT[:items]).
    def per_page_vars(per_page)
      return {} if per_page.blank?

      { items: per_page.to_i.clamp(1, MAX_PER_PAGE) }
    end

    # In-memory filter on top of Valkyrie's find_all_of_model. Cheap for the
    # small in-progress monitoring use case; revisit with a Solr-backed
    # query if the dataset grows.
    def apply_filters(results, filters)
      results.select do |resource|
        filters.all? { |attr, val| resource.public_send(attr) == val }
      end
    end
end
