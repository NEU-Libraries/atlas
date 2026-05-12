# frozen_string_literal: true

# Records that a particular (user, key) pair already produced a resource.
# Used by IdempotentCreate to short-circuit duplicate create requests when
# Cerberus's Solid Queue retries a job whose Atlas-side write already
# committed. Stores `(resource_type, resource_noid)` so the replay path
# can re-render the original resource without storing the response body.
class IdempotencyKey < ApplicationRecord
  belongs_to :user

  validates :key, :resource_type, :resource_noid, presence: true
  validates :key, uniqueness: { scope: :user_id }
end
