# frozen_string_literal: true

# Records that a particular (user, key, resource_type) triple already produced
# a resource. Used by IdempotentCreate to short-circuit duplicate create
# requests when Cerberus's Solid Queue retries a job whose Atlas-side write
# already committed. Stores `resource_noid` so the replay path can re-render
# the original resource without storing the response body.
#
# resource_type belongs in the identity because a key names an *operation*,
# and one batch-load row legitimately creates a Work and then its Blob under
# its single key. The scope and the unique index have to agree: while they
# didn't, the Blob's key could neither replay nor record.
class IdempotencyKey < ApplicationRecord
  belongs_to :user

  validates :key, :resource_type, :resource_noid, presence: true
  validates :key, uniqueness: { scope: %i[user_id resource_type] }
end
