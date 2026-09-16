# frozen_string_literal: true

# Valkyrie custom query: Person resources by NUID. Resource.find resolves a
# NOID or Valkyrie id only, so NUID-keyed lookups need this. See
# docs/people.md.
#
# Valkyrie ARRAY-WRAPS scalar attribute values in the jsonb, so a String nuid
# lands as {"nuid":["..."]} and the containment predicate must match that
# shape. Scoped to the Person internal_resource so it can never match another
# type.
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

    # Private on the postgres query service, so each handler reimplements it.
    # find_by_sql's array form parameterizes the binds.
    def run_query(query, *args)
      orm.find_by_sql([query, *args]).map do |object|
        @query_service.resource_factory.to_resource(object: object)
      end
    end

    def orm
      Valkyrie::Persistence::Postgres::ORM::Resource
    end
end
