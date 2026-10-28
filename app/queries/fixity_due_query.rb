# frozen_string_literal: true

# The OCFL objects most in need of a fixity check: never checked first, then
# oldest check first. Read off the storage ledger, which holds one row per
# object the adapter has written, so an object with no check yet is listed too.
# See docs/fixity.md.
class FixityDueQuery
  MAX_LIMIT = 1000

  SQL = <<~SQL.squish
    SELECT footprint.object_key, footprint.bytes, result.checked_at
    FROM storage_footprints footprint
    LEFT JOIN fixity_results result ON result.object_key = footprint.object_key
    WHERE result.checked_at IS NULL OR result.checked_at < :before
    ORDER BY result.checked_at ASC NULLS FIRST, footprint.object_key ASC
    LIMIT :limit
  SQL

  Row = Struct.new(:key, :bytes, :last_checked_at, keyword_init: true)

  # `before` is the sweep's cutoff, a re-check cycle before its start, so an
  # object it has just checked drops out and the next page needs no cursor.
  def self.call(limit:, before:)
    sql = ActiveRecord::Base.sanitize_sql([SQL, { before: before, limit: limit.clamp(1, MAX_LIMIT) }])
    ActiveRecord::Base.connection.select_rows(sql).map do |key, bytes, checked_at|
      Row.new(key: key, bytes: bytes.to_i, last_checked_at: checked_at && Time.zone.parse(checked_at.to_s))
    end
  end
end
