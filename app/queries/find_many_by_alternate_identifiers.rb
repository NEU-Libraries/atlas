# frozen_string_literal: true

# Valkyrie custom query: many resources by NOID in a single index-backed
# query, instead of one round-trip per id. See docs/read-performance.md.
#
# Each disjunct is the exact `metadata @>` predicate
# find_by_alternate_identifier uses, so every term hits the jsonb_path_ops GIN
# index. Ids ride as bind parameters; only the placeholder count is built from
# input.
class FindManyByAlternateIdentifiers
  def self.queries
    [:find_many_by_alternate_identifiers]
  end

  def initialize(query_service:)
    @query_service = query_service
  end

  def find_many_by_alternate_identifiers(alternate_identifiers:)
    ids = Array(alternate_identifiers).map(&:to_s).uniq
    return [] if ids.empty?

    where = (['metadata @> ?'] * ids.size).join(' OR ')
    binds = ids.map { |id| %({"alternate_ids":[{"id":"#{id}"}]}) }
    run_query("SELECT * FROM orm_resources WHERE #{where}", *binds)
  end

  private

    # run_query is private on the postgres query service, so a custom-query
    # handler reimplements it (the pattern the Valkyrie docs' figgy example
    # uses). find_by_sql's array form parameterizes the binds.
    def run_query(query, *args)
      orm.find_by_sql([query, *args]).map do |object|
        @query_service.resource_factory.to_resource(object: object)
      end
    end

    def orm
      Valkyrie::Persistence::Postgres::ORM::Resource
    end
end
