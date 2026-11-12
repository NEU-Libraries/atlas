# frozen_string_literal: true

# Valkyrie custom query: the Works holding a handle, live or tombstoned. A
# purged Work is gone from the table, and its handle with it.
#
# The `metadata @>` predicate hits the jsonb_path_ops GIN index, so the check
# stays cheap across a bulk migration. Valkyrie stores every attribute as an
# array, hence the one-element list.
class FindWorksByHandle
  def self.queries
    [:find_works_by_handle]
  end

  def initialize(query_service:)
    @query_service = query_service
  end

  def find_works_by_handle(handle:)
    sql = "SELECT * FROM orm_resources WHERE internal_resource = 'Work' AND metadata @> ?"
    orm.find_by_sql([sql, { handle: [handle.to_s] }.to_json]).map do |object|
      @query_service.resource_factory.to_resource(object: object)
    end
  end

  private

    def orm
      Valkyrie::Persistence::Postgres::ORM::Resource
    end
end
