# frozen_string_literal: true

# The on-disk bytes of one OCFL object, keyed by its object key (the resource
# NOID). The storage adapter adds to it on every version write and drops it
# with the object. See docs/binaries.md.
#
# Both writes are upserts: the row has no validations to skip, and a
# read-then-save would race a concurrent write to the same object.
class StorageFootprint < ApplicationRecord
  self.primary_key = 'object_key'

  # One statement, so two writes to the same object cannot lose an increment.
  def self.add!(key:, bytes:)
    now = Time.current
    upsert({ object_key: key.to_s, bytes: bytes, created_at: now, updated_at: now }, # rubocop:disable Rails/SkipsModelValidations
           unique_by:    :object_key,
           on_duplicate: Arel.sql('bytes = storage_footprints.bytes + EXCLUDED.bytes, ' \
                                  'updated_at = EXCLUDED.updated_at'))
  end

  # Replaces the total outright, for a rebuild measured from disk.
  def self.set!(key:, bytes:)
    now = Time.current
    upsert({ object_key: key.to_s, bytes: bytes, created_at: now, updated_at: now }, # rubocop:disable Rails/SkipsModelValidations
           unique_by: :object_key)
  end

  def self.forget!(key:)
    where(object_key: key.to_s).delete_all
  end
end
