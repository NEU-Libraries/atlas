# frozen_string_literal: true

# Valkyrie custom query: resolve the children of many parents in two queries
# instead of two per parent.
#
# Registered on the postgres query service in config/initializers/valkyrie.rb;
# reach it as `Atlas.query.custom_queries.find_many_members`.
#
# Atlas records containment from both ends (see Relationships#children), so a
# batch needs both directions:
#
#   * `a_member_of` on the child — one disjunction of the same `metadata @> ?`
#     containment predicate find_inverse_references_by builds, so every term
#     hits the jsonb_path_ops GIN index. Grouped by reading the edge back off
#     each child.
#   * `member_ids` on the parent — the find_members lateral join, widened to a
#     set of parents with `a.id IN (…)` and carrying the parent id out as an
#     alias so the rows can be grouped without a second pass.
#
# Ids ride as bind parameters; only the placeholder count is built from input.
# Postgres-specific by construction, like FindManyByAlternateIdentifiers.
#
# Two queries, mirroring the two unbatched reads they replace:
# find_many_members is the batched `children` (the union, both directions) and
# find_many_ordered_members is the batched find_members (member_ids only, in
# stored order). Keeping them apart matters — page order comes off member_ids,
# and the union puts the inverse direction first.
class FindManyMembers
  def self.queries
    %i[find_many_members find_many_ordered_members]
  end

  def initialize(query_service:)
    @query_service = query_service
  end

  # @return [Hash{String => Array<Valkyrie::Resource>}] parent Valkyrie id
  #   (as a string) => its children. Child order matches
  #   Relationships#children — inverse `a_member_of` first, then `member_ids`
  #   in stored order — so a preloaded read sees what an unbatched one would.
  #   Parents with no children are absent, not empty; callers default.
  def find_many_members(resources:)
    ids = parent_ids(resources)
    return {} if ids.empty?

    grouped = inverse_members(ids)
    ordered_members(ids).each { |parent_id, members| (grouped[parent_id] ||= []).concat(members) }
    grouped.each_value(&:uniq!)
    grouped
  end

  # The batched equivalent of find_members: member_ids only, in stored order.
  # @return [Hash{String => Array<Valkyrie::Resource>}] as find_many_members.
  def find_many_ordered_members(resources:)
    ids = parent_ids(resources)
    return {} if ids.empty?

    ordered_members(ids)
  end

  private

    def parent_ids(resources)
      Array(resources).map { |r| r.id.to_s }.reject(&:blank?).uniq
    end

    # Children pointing up via a_member_of. The edge is scalar on the backbone
    # (Collection, Work) and plural elsewhere, so it is read as an array either
    # way; a child is grouped under every parent in the requested set that it
    # names.
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

    # Children listed in the parent's own member_ids, in stored order. The
    # parent id is selected alongside `member.*` under an alias so it survives
    # into the ORM row without shadowing the member's own id column.
    def ordered_members(ids)
      placeholders = (['?'] * ids.size).join(', ')
      sql = <<-SQL.squish
        SELECT member.*, a.id AS find_many_members_parent_id
        FROM orm_resources a,
        jsonb_array_elements(a.metadata->'member_ids') WITH ORDINALITY AS b(member, member_pos)
        JOIN orm_resources member ON (b.member->>'id')::uuid = member.id
        WHERE a.id IN (#{placeholders})
        ORDER BY a.id, b.member_pos
      SQL

      orm.find_by_sql([sql, *ids]).group_by { |row| row.find_many_members_parent_id.to_s }
         .transform_values { |rows| rows.map { |row| to_resource(row) } }
    end

    # run_query is private on the postgres query service, so a custom-query
    # handler reimplements it (the pattern FindManyByAlternateIdentifiers and
    # the Valkyrie docs' figgy example both follow).
    def run_query(query, *args)
      orm.find_by_sql([query, *args]).map { |object| to_resource(object) }
    end

    def to_resource(object)
      @query_service.resource_factory.to_resource(object: object)
    end

    def orm
      Valkyrie::Persistence::Postgres::ORM::Resource
    end
end
