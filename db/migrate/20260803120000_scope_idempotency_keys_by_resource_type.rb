# frozen_string_literal: true

# IdempotentCreate looks a key up scoped to the resource class, but the unique
# index covered only (user_id, key) — so one key reused across two classes was
# not treated as a replay (different class), yet could not be recorded either.
# The insert failed *after* the resource had been persisted, so the caller got
# a 422 for a create that had in fact landed.
#
# Widening the index is safe on existing rows: anything unique on two columns
# is already unique on three.
class ScopeIdempotencyKeysByResourceType < ActiveRecord::Migration[7.0]
  def up
    remove_index :idempotency_keys, column: %i[user_id key], unique: true
    add_index :idempotency_keys, %i[user_id key resource_type], unique: true
  end

  def down
    remove_index :idempotency_keys, column: %i[user_id key resource_type], unique: true
    add_index :idempotency_keys, %i[user_id key], unique: true
  end
end
