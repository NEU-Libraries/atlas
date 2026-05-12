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
