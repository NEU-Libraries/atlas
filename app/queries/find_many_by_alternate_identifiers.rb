# frozen_string_literal: true

# Valkyrie custom query: resolve many resources by their alternate identifier
# (NOID) in a single index-backed query, instead of N calls to
# find_by_alternate_identifier (one HTTP/DB round-trip per id).
#
# Registered on the postgres query service in config/initializers/valkyrie.rb;
# reach it as `Atlas.query.custom_queries.find_many_by_alternate_identifiers`.
#
# Each disjunct is the exact `metadata @>` containment predicate that
# find_by_alternate_identifier uses, so every term hits the jsonb_path_ops GIN
# index on orm_resources.metadata. The ids ride as bind parameters (never
# interpolated into the SQL string); only the placeholder *count* is built from
# input. Postgres-specific by construction — it is registered solely against
# the postgres-backed query service that both composite adapters read through.
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
