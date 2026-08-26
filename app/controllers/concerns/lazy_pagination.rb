# frozen_string_literal: true

module LazyPagination
  include Pagy::Backend
  extend ActiveSupport::Concern

  # Caps caller-supplied per_page so a request can't ask for an unbounded page.
  MAX_PER_PAGE = 100

  # Unfiltered, the page is read straight out of Postgres (COUNT(*) plus
  # LIMIT/OFFSET) via ModelPage. Filtered, the filter is in-memory so the whole
  # model still has to be walked — but only once, into an array, rather than
  # once to count and again to reach the offset.
  def paginate_model(klass, filters: {}, per_page: nil)
    scope = filters.present? ? filtered_all(klass, filters) : ModelPage.new(klass)
    pagy, items = pagy(scope, count: scope.count, **per_page_vars(per_page))
    [pagy_metadata(pagy), items]
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

  # Serves all three shapes paginate_model and paginate_array pass in: a
  # ModelPage reads its slice from Postgres, an array or a lazy enumerator is
  # sliced in memory.
  def pagy_get_items(collection, pagy)
    return collection.page(limit: pagy.items, offset: pagy.offset) if collection.is_a?(ModelPage)

    collection.drop(pagy.offset).first(pagy.items)
  end

  # A model's resources as a countable, sliceable page source, so pagy keeps
  # doing the page parsing and overflow handling while the count and the slice
  # go to SQL instead of to a full enumeration.
  class ModelPage
    def initialize(klass)
      @klass = klass
    end

    def count
      Atlas.query.custom_queries.count_of_model(model: @klass)
    end

    def page(limit:, offset:)
      Atlas.query.custom_queries.find_page_of_model(model: @klass, limit: limit, offset: offset)
    end
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
    # query if the dataset grows. Materialized here so the count and the slice
    # share one walk of the model.
    def filtered_all(klass, filters)
      Atlas.query.find_all_of_model(model: klass).select do |resource|
        filters.all? { |attr, val| resource.public_send(attr) == val }
      end.to_a
    end
end
