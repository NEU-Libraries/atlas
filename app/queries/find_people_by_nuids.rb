# frozen_string_literal: true

# Valkyrie custom query: resolve Person resources by their NUID — the People
# surface's correlation key and public address. Resource.find only resolves
# NOID / Valkyrie id, so NUID-keyed lookups (GET /people/:nuid, the authoritative
# display_name batch-resolve that supersedes User.resolve) need this.
#
# Registered on the postgres query service in config/initializers/valkyrie.rb;
# reach it as `Atlas.query.custom_queries.find_person_by_nuid` /
# `find_people_by_nuids`.
#
# Each disjunct is a `metadata @>` containment predicate (Valkyrie array-wraps
# scalar attribute values in the jsonb, so a String nuid lands as
# {"nuid":["..."]}), scoped to the Person internal_resource so it can never
# match another type. NUIDs ride as bind parameters; only the placeholder count
# derives from input. Postgres-specific, like FindManyByAlternateIdentifiers.
class FindPeopleByNuids
  def self.queries
    %i[find_person_by_nuid find_people_by_nuids]
  end

  def initialize(query_service:)
    @query_service = query_service
  end

  def find_person_by_nuid(nuid:)
    find_people_by_nuids(nuids: [nuid]).first
  end

  def find_people_by_nuids(nuids:)
    ids = Array(nuids).map(&:to_s).uniq.compact_blank
    return [] if ids.empty?

    where = (['metadata @> ?'] * ids.size).join(' OR ')
    binds = ids.map { |nuid| %({"nuid":["#{nuid}"]}) }
    run_query("SELECT * FROM orm_resources WHERE internal_resource = 'Person' AND (#{where})", *binds)
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
