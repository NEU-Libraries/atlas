# frozen_string_literal: true

# Valkyrie custom query: count, and fetch one page of, the resources of a
# model — the two reads a paginated index needs.
#
# Registered on the postgres query service in config/initializers/valkyrie.rb;
# reach it as `Atlas.query.custom_queries.count_of_model` /
# `.find_page_of_model`.
#
# find_all_of_model returns a lazy enumerator over the whole model, so
# paginating it meant counting by enumerating every row and then enumerating
# again to reach the offset — two full passes, and every row instantiated as a
# Valkyrie resource, to serve ten. Here the count is a COUNT(*) and the page is
# a LIMIT/OFFSET. The ORDER BY matches find_all_of_model's (id ASC), so page
# boundaries stay where they were.
class FindPageOfModel
  def self.queries
    %i[count_of_model find_page_of_model]
  end

  def initialize(query_service:)
    @query_service = query_service
  end

  def count_of_model(model:)
    orm.where(internal_resource: model.to_s).count
  end

  def find_page_of_model(model:, limit:, offset: 0)
    orm.where(internal_resource: model.to_s)
       .order(id: :asc)
       .limit(limit)
       .offset(offset)
       .map { |object| @query_service.resource_factory.to_resource(object: object) }
  end

  private

    def orm
      Valkyrie::Persistence::Postgres::ORM::Resource
    end
end
