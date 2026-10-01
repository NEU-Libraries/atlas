# frozen_string_literal: true

# The stored bytes a Work, Collection or Community owns itself, summed from the
# storage_footprints ledger: its own object and everything under it short of
# the next Work, Collection or Community. A Work owns its FileSets and their
# Blobs; a container owns its MODS FileSet and Blob and its METS Blob. Indexed
# per resource, so a subtree is a Solr sum. See docs/binaries.md.
#
# Follows the two edges the graph stores: a child's a_member_of and a parent's
# member_ids. a_linked_member_of is never followed.
class StorageFootprintQuery
  OWNER_TYPES = %w[Work Collection Community].freeze

  OWN_SQL = <<~SQL.squish
    WITH RECURSIVE owned(id) AS (
      SELECT id FROM orm_resources WHERE id = :root
      UNION
      SELECT child.id
      FROM owned
      JOIN orm_resources parent ON parent.id = owned.id
      CROSS JOIN LATERAL (
        SELECT (member->>'id')::uuid AS id
        FROM jsonb_array_elements(COALESCE(parent.metadata->'member_ids', '[]'::jsonb)) AS member
        UNION ALL
        SELECT inverse.id FROM orm_resources inverse
        WHERE inverse.metadata @> jsonb_build_object(
          'a_member_of', jsonb_build_array(jsonb_build_object('id', parent.id::text)))
      ) edge
      JOIN orm_resources child ON child.id = edge.id
      WHERE child.internal_resource NOT IN (:owner_types)
    )
    SELECT COALESCE(SUM(footprint.bytes), 0) AS bytes
    FROM owned
    JOIN orm_resources resource ON resource.id = owned.id
    JOIN storage_footprints footprint
      ON footprint.object_key = COALESCE(resource.metadata->'alternate_ids'->0->>'id', resource.id::text)
  SQL

  def self.own_bytes(resource)
    sql = ActiveRecord::Base.sanitize_sql([OWN_SQL, { root: resource.id.to_s, owner_types: OWNER_TYPES }])
    ActiveRecord::Base.connection.select_value(sql).to_i
  end
end
