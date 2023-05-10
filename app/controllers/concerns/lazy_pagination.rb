module LazyPagination
  include Pagy::Backend
  extend ActiveSupport::Concern

  def paginate_model(klass)
    results = Atlas.query.find_all_of_model(model: klass)
    pagy, items = pagy(results, count: results.count)
    pagination = pagy_metadata(pagy)
    return pagination, items
  end

  def pagy_get_items(lazy, pagy)
    lazy.drop(pagy.offset).first(pagy.items)
  end
end
