# frozen_string_literal: true

# Valkyrie custom query: the resource holding a v1 pid, live or tombstoned, or
# nil. No type filter, because the pid is unique across every type.
#
# The `metadata @>` predicate hits the jsonb_path_ops GIN index, so the check
# stays cheap across a bulk migration. Valkyrie stores every attribute as an
# array, hence the one-element list.
class FindResourceByLegacyPid
  def self.queries
    [:find_resource_by_legacy_pid]
  end

  def initialize(query_service:)
    @query_service = query_service
  end

  def find_resource_by_legacy_pid(legacy_pid:)
    sql = 'SELECT * FROM orm_resources WHERE metadata @> ? LIMIT 1'
    object = orm.find_by_sql([sql, { legacy_pid: [legacy_pid.to_s] }.to_json]).first
    object && @query_service.resource_factory.to_resource(object: object)
  end

  private

    def orm
      Valkyrie::Persistence::Postgres::ORM::Resource
    end
end
