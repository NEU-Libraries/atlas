# frozen_string_literal: true

# A Work's extracted document text, one row per Work keyed by its Valkyrie id.
# It lives outside orm_resources so that saving or reading the Work never
# carries the text. See docs/resource-graph.md.
class WorkFullText < ApplicationRecord
  self.primary_key = :work_id

  # Blank text deletes the row, so an empty PATCH clears the Work's text.
  def self.store(work_id:, text:)
    if text.blank?
      where(work_id: work_id.to_s).delete_all
    else
      # rubocop:disable Rails/SkipsModelValidations -- the model has no validations,
      # and one statement keeps a retried PATCH idempotent.
      upsert({ work_id: work_id.to_s, body: text }, unique_by: :work_id)
      # rubocop:enable Rails/SkipsModelValidations
    end
  end

  def self.body_for(work_id)
    return nil if work_id.blank?

    where(work_id: work_id.to_s).pick(:body)
  end
end
