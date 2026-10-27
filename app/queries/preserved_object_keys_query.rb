# frozen_string_literal: true

# The object keys of everything a Work owns that carries an OCFL object: the
# Work, its FileSets other than the Derivative one, and their Blobs. The same
# set as Work#preserved_resources in one statement, because the Work's index
# runs it and a walk would cost a query per FileSet. See docs/fixity.md.
class PreservedObjectKeysQuery
  SQL = <<~SQL.squish
    WITH file_sets AS (
      SELECT fs.id, fs.metadata
      FROM orm_resources fs
      WHERE fs.internal_resource = 'FileSet'
        AND fs.metadata @> jsonb_build_object('a_member_of', jsonb_build_array(jsonb_build_object('id', :work)))
        AND NOT COALESCE(fs.metadata->'type', '[]'::jsonb) @> to_jsonb(CAST(:derivative AS text))
    ),
    objects AS (
      SELECT CAST(:work AS uuid) AS id
      UNION SELECT id FROM file_sets
      UNION SELECT CAST(member->>'id' AS uuid)
      FROM file_sets CROSS JOIN LATERAL jsonb_array_elements(COALESCE(file_sets.metadata->'member_ids', '[]'::jsonb)) AS member
    )
    SELECT COALESCE(resource.metadata->'alternate_ids'->0->>'id', resource.id::text)
    FROM objects
    JOIN orm_resources resource ON resource.id = objects.id
    WHERE resource.internal_resource IN ('Work', 'FileSet', 'Blob')
  SQL

  def self.keys_for(work)
    sql = ActiveRecord::Base.sanitize_sql([SQL, { work: work.id.to_s, derivative: Classification.derivative.name }])
    ActiveRecord::Base.connection.select_values(sql)
  end
end
