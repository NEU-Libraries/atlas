# frozen_string_literal: true

# The latest fixity check recorded for one OCFL object, keyed by its object key
# (the resource NOID). A cache over the object's logs/fixity.jsonl, which is
# the record. See docs/fixity.md.
class FixityResult < ApplicationRecord
  self.primary_key = 'object_key'

  RESULTS = %w[pass fail].freeze

  # Worst first, so a Work reports the worst outcome among its objects.
  SEVERITY = { 'fail' => 0, 'pass' => 1 }.freeze

  # One statement, and only ever forward in checked_at: a result posted late,
  # or replayed, must not replace a newer one. A read-then-save would race a
  # concurrent post for the same object.
  def self.advance!(key:, checked_at:, result:, version:, checker:)
    now = Time.current
    upsert({ object_key: key.to_s, checked_at: checked_at, result: result, version: version, # rubocop:disable Rails/SkipsModelValidations
             checker: checker, created_at: now, updated_at: now },
           unique_by:    :object_key,
           on_duplicate: Arel.sql(<<~SQL.squish))
             checked_at = EXCLUDED.checked_at, result = EXCLUDED.result, version = EXCLUDED.version,
             checker = EXCLUDED.checker, updated_at = EXCLUDED.updated_at
             WHERE fixity_results.checked_at <= EXCLUDED.checked_at
           SQL
  end

  # The recorded checks over a set of objects, not a re-hash. A Work is only as
  # verified as its least recently checked object, so one never checked leaves
  # last_checked_at null; result is the worst outcome recorded.
  def self.summary(keys)
    rows   = where(object_key: keys).to_a
    never  = keys.size - rows.size
    oldest = never.zero? ? rows.map(&:checked_at).min : nil
    { last_checked_at: oldest&.utc&.iso8601,
      result:          rows.map(&:result).min_by { |result| SEVERITY.fetch(result) },
      objects:         keys.size,
      never_checked:   never }
  end

  # Replaces the row outright, for a rebuild read from the logs.
  def self.set!(key:, checked_at:, result:, version:, checker:)
    now = Time.current
    upsert({ object_key: key.to_s, checked_at: checked_at, result: result, version: version, # rubocop:disable Rails/SkipsModelValidations
             checker: checker, created_at: now, updated_at: now },
           unique_by: :object_key)
  end
end
