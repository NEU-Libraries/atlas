# frozen_string_literal: true

# Valkyrie custom query: resolve the parent of many resources in two queries
# instead of two per resource — the inverse of FindManyMembers.
#
# Registered on the postgres query service in config/initializers/valkyrie.rb;
# reach it as `Atlas.query.custom_queries.find_many_parents`.
#
# Atlas records containment from both ends (see Relationships#parent), so a
# batch reads both, in the same precedence order the unbatched read uses:
#
#   * `a_member_of` on the child — the edge is stored on the child itself, so
#     the ids come off the resources already in hand and resolve in one
#     find_many_by_ids.
#   * `member_ids` on the parent — one disjunction of the `metadata @> ?`
#     containment predicate find_inverse_references_by builds, so every term
#     hits the jsonb_path_ops GIN index. This is the only direction a Blob has:
#     Blobs declare no `a_member_of`, their linkage lives in the parent
#     FileSet's member_ids.
#
# Ids ride as bind parameters; only the placeholder count is built from input.
# Postgres-specific by construction, like FindManyMembers.
class FindManyParents
  def self.queries
    [:find_many_parents]
  end

  def initialize(query_service:)
    @query_service = query_service
  end

  # @return [Hash{String => Valkyrie::Resource}] child Valkyrie id (as a
  #   string) => its parent. Children with no resolvable parent are absent,
  #   not nil — callers default. A child naming several `a_member_of` ids
  #   answers the first that resolves, matching Relationships#parent's `.first`.
  def find_many_parents(resources:)
    children = Array(resources).compact.uniq(&:id)
    return {} if children.empty?

    parents = forward_parents(children)
    parents.merge(inverse_parents(children.reject { |child| parents.key?(child.id.to_s) }))
  end

  private

    # Children pointing up via their own `a_member_of`. One query for every
    # named parent, then each child is matched back to the first of its ids
    # that resolved.
    def forward_parents(children)
      edges = children.to_h { |child| [child.id.to_s, edge_ids(child)] }.reject { |_id, ids| ids.empty? }
      return {} if edges.empty?

      resolved = @query_service.find_many_by_ids(ids: edges.values.flatten.uniq).index_by { |r| r.id.to_s }
      edges.each_with_object({}) do |(child_id, parent_ids), result|
        parent = parent_ids.lazy.filter_map { |id| resolved[id] }.first
        result[child_id] = parent if parent
      end
    end

    # Parents listing the child in their own member_ids. Read as an array
    # whichever end declares it, and grouped by walking each parent's
    # member_ids back down — a parent row can cover several of the requested
    # children at once (a FileSet holding many Blobs).
    def inverse_parents(children)
      ids = children.map { |child| child.id.to_s }
      return {} if ids.empty?

      wanted = ids.to_set
      parents_listing(ids).each_with_object({}) do |parent, result|
        listed_children(parent, wanted).each { |child_id| result[child_id] ||= parent }
      end
    end

    # The requested children a parent row lists in its own member_ids. One row
    # can cover several of them at once (a FileSet holding many Blobs).
    def listed_children(parent, wanted)
      Array(parent.try(:member_ids)).map(&:to_s).select { |child_id| wanted.include?(child_id) }
    end

    def parents_listing(ids)
      where = (['metadata @> ?'] * ids.size).join(' OR ')
      binds = ids.map { |id| %({"member_ids":[{"id":"#{id}"}]}) }
      run_query("SELECT * FROM orm_resources WHERE #{where}", *binds)
    end

    # `a_member_of` is scalar on the backbone and absent on leaves (Blob), so
    # normalise to an array and skip a resource that does not declare it at all.
    def edge_ids(child)
      return [] unless child.respond_to?(:a_member_of)

      value = child.a_member_of
      (value.is_a?(Array) ? value : [value]).compact.map(&:to_s).compact_blank
    end

    # run_query is private on the postgres query service, so a custom-query
    # handler reimplements it (the pattern FindManyByAlternateIdentifiers and
    # FindManyMembers both follow).
    def run_query(query, *args)
      orm.find_by_sql([query, *args]).map { |object| @query_service.resource_factory.to_resource(object: object) }
    end

    def orm
      Valkyrie::Persistence::Postgres::ORM::Resource
    end
end
