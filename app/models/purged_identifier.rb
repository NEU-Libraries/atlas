# frozen_string_literal: true

# A NOID that ResourcePurger removed. Not derived from disk and not rebuildable
# from it: the purge deleted the object that would have said so. See
# docs/resource-graph.md.
class PurgedIdentifier < ApplicationRecord
  self.primary_key = :noid

  # Written before anything is deleted, and idempotent, so a purge retried after
  # a partial failure keeps the first purge's time and actor.
  def self.record!(resources, purged_by:)
    now = Time.current
    rows = resources.map do |resource|
      { noid: resource.noid, resource_type: resource.class.name, purged_at: now, purged_by: purged_by }
    end
    # The model has no validations to skip, and ON CONFLICT is what keeps the first row.
    insert_all(rows, unique_by: :noid) if rows.any? # rubocop:disable Rails/SkipsModelValidations
  end
end
