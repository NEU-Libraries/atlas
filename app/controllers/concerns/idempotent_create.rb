# frozen_string_literal: true

# Cerberus's per-record Solid Queue jobs need create calls to be safely
# retryable: if Atlas succeeds but Cerberus crashes before recording the
# success, the retry must not produce a duplicate resource.
#
# Including controllers declare the resource they own:
#
#   class WorksController < ApplicationController
#     include IdempotentCreate
#     idempotent_for resource_class: Work, var: :work
#
#     def create
#       @work = WorkCreator.call(parent_id: params[:collection_id])
#       record_idempotency_key!(@work.noid)
#     end
#   end
#
# Replay model is lookup-and-re-render — the key maps to a NOID and the
# concern re-renders the resource at its current state. Tombstoned
# replays return 410 + tombstone payload so the create path agrees with
# the GET path (see TombstoneAware).
module IdempotentCreate
  extend ActiveSupport::Concern

  included do
    class_attribute :idempotent_resource_class
    class_attribute :idempotent_var
    class_attribute :idempotent_decorate, default: true

    before_action :idempotency_key_replay, only: :create
  end

  class_methods do
    def idempotent_for(resource_class:, var:, decorate: true)
      self.idempotent_resource_class = resource_class
      self.idempotent_var = var
      self.idempotent_decorate = decorate
    end
  end

  private

    def idempotency_key_replay
      key = request.headers['Idempotency-Key']
      return if key.blank?

      record = IdempotencyKey.find_by(
        user_id: @current_user.id, key: key,
        resource_type: self.class.idempotent_resource_class.name
      )
      return unless record

      resource = self.class.idempotent_resource_class.find(record.resource_noid)
      return head(:gone) if resource.nil?

      resource = resource.decorate if self.class.idempotent_decorate
      instance_variable_set("@#{self.class.idempotent_var}", resource)

      if resource.tombstoned
        render :show, status: :gone
      else
        render :create
      end
    end

    def record_idempotency_key!(resource_noid)
      key = request.headers['Idempotency-Key']
      return if key.blank?

      IdempotencyKey.create!(
        user: @current_user, key: key,
        resource_type: self.class.idempotent_resource_class.name,
        resource_noid: resource_noid
      )
    rescue ActiveRecord::RecordNotUnique
      # Concurrent retry committed the key first; the resource we just
      # created is the duplicate. Rare window; log and move on.
      Rails.logger.warn(
        "[IdempotentCreate] lost the race recording key=#{key} " \
        "for #{self.class.idempotent_resource_class.name}=#{resource_noid}"
      )
    end
end
