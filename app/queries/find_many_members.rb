# frozen_string_literal: true

# Valkyrie custom query: the children of many parents in two queries instead
# of two per parent. See docs/read-performance.md.
#
# Registered in config/initializers/valkyrie.rb; reach it as
# `Atlas.query.custom_queries.find_many_members`.
#
# It answers TWO named queries and they must stay apart: page order comes off
# member_ids, and the union puts the inverse direction first, so conflating
# them would reorder a Work's pages.
#
# Ids ride as bind parameters; only the placeholder count is built from input.
class FindManyMembers
  def self.queries
    %i[find_many_members find_many_ordered_members]
  end

  def initialize(query_service:)
    @query_service = query_service
  end

  # Child order matches Relationships#children, so a preloaded read sees what
  # an unbatched one would. Parents with no children are ABSENT, not empty.
  def find_many_members(resources:)
    ids = parent_ids(resources)
    return {} if ids.empty?

    grouped = inverse_members(ids)
    ordered_members(ids).each { |parent_id, members| (grouped[parent_id] ||= []).concat(members) }
    grouped.each_value(&:uniq!)
    grouped
  end

  # member_ids only, in stored order -- the batched find_members.
  def find_many_ordered_members(resources:)
    ids = parent_ids(resources)
    return {} if ids.empty?

    ordered_members(ids)
  end

  private

    def parent_ids(resources)
      Array(resources).map { |r| r.id.to_s }.compact_blank.uniq
    end

    # The a_member_of edge is scalar on the backbone and plural elsewhere, so
    # it is read as an array either way.
    def inverse_members(ids)
      where = (['metadata @> ?'] * ids.size).join(' OR ')
      binds = ids.map { |id| %({"a_member_of":[{"id":"#{id}"}]}) }
      wanted = ids.to_set

      run_query("SELECT * FROM orm_resources WHERE #{where}", *binds)
        .each_with_object({}) do |child, grouped|
          Array(child.try(:a_member_of)).map(&:to_s).each do |parent_id|
            (grouped[parent_id] ||= []) << child if wanted.include?(parent_id)
          end
        end
    end

    # The parent id is selected under an ALIAS so it survives into the ORM row
    # without shadowing the member's own id column.
    def ordered_members(ids)
      placeholders = (['?'] * ids.size).join(', ')
      sql = <<~SQL.squish
        SELECT member.*, a.id AS find_many_members_parent_id
        FROM orm_resources a,
        jsonb_array_elements(a.metadata->'member_ids') WITH ORDINALITY AS b(member, member_pos)
        JOIN orm_resources member ON (b.member->>'id')::#{id_type} = member.id
        WHERE a.id IN (#{placeholders})
        ORDER BY a.id, b.member_pos
      SQL

      orm.find_by_sql([sql, *ids]).group_by { |row| row.find_many_members_parent_id.to_s }
         .transform_values { |rows| rows.map { |row| to_resource(row) } }
    end

    # Private on the postgres query service, so each custom-query handler
    # reimplements it -- the pattern the Valkyrie docs' figgy example follows.
    def run_query(query, *args)
      orm.find_by_sql([query, *args]).map { |object| to_resource(object) }
    end

    def to_resource(object)
      @query_service.resource_factory.to_resource(object: object)
    end

    def orm
      Valkyrie::Persistence::Postgres::ORM::Resource
    end

    # Off the column rather than hardcoded, matching Valkyrie's own cast.
    def id_type
      @id_type ||= orm.columns_hash['id'].type
    end
end
