# frozen_string_literal: true

module LazyPagination
  include Pagy::Backend
  extend ActiveSupport::Concern

  def paginate_model(klass, filters: {})
    results = Atlas.query.find_all_of_model(model: klass)
    results = apply_filters(results, filters) if filters.present?
    pagy, items = pagy(results, count: results.count)
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

    # In-memory filter on top of Valkyrie's find_all_of_model. Cheap for the
    # small in-progress monitoring use case; revisit with a Solr-backed
    # query if the dataset grows.
    def apply_filters(results, filters)
      results.select do |resource|
        filters.all? { |attr, val| resource.public_send(attr) == val }
      end
    end
end
