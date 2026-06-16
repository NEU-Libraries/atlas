# frozen_string_literal: true

# Helpers for replay-safe create endpoints. Cerberus's per-record Solid
# Queue jobs send an `Idempotency-Key` header so that an Atlas-side
# commit followed by a Cerberus crash doesn't produce a duplicate
# resource on retry.
#
# Controllers wire the three helpers explicitly from their create action:
#
#   def create
#     if (record = find_idempotency_record(Work))
#       @work = Work.find(record.resource_noid)&.decorate
#       return render_idempotent_resource(@work)
#     end
#     @work = WorkCreator.call(parent_id: params[:collection_id])
#     record_idempotency_key!(@work.noid, Work)
#   end
#
# Keeping the dispatch in the action body (rather than a before_action +
# class macros) so a first-time reader of the controller can see the
# whole flow in one place.
module IdempotentCreate
  extend ActiveSupport::Concern

  private

    # Returns the IdempotencyKey row for the (current user, header)
    # pair scoped to the given resource class, or nil if no replay
    # applies (no header, no auth context, or no matching record).
    def find_idempotency_record(resource_class)
      key = request.headers['Idempotency-Key']
      return if key.blank? || @current_user.nil?

      IdempotencyKey.find_by(
        user_id: @current_user.id, key: key,
        resource_type: resource_class.name
      )
    end

    # Render a replay response for a resource the caller has just
    # loaded and assigned. head(:gone) if the resource is missing
    # (hard-deleted), :show + 410 if tombstoned, otherwise the given view
    # (defaults to :create; the FileSet attach replay passes :update since
    # the idempotent operation there is a PATCH, not a POST).
    def render_idempotent_resource(resource, view: :create)
      return head(:gone) if resource.nil?
      return render(:show, status: :gone) if resource.tombstoned

      render view
    end

    # Persist the key after a successful create. No-op when there's no
    # header or no auth context. Concurrent retries that lose the
    # uniqueness race log a warning and continue — the resource we just
    # created is the duplicate in that case.
    def record_idempotency_key!(resource_noid, resource_class)
      key = request.headers['Idempotency-Key']
      return if key.blank? || @current_user.nil?

      IdempotencyKey.create!(
        user: @current_user, key: key,
        resource_type: resource_class.name,
        resource_noid: resource_noid
      )
    rescue ActiveRecord::RecordNotUnique
      Rails.logger.warn(
        "[IdempotentCreate] lost the race recording key=#{key} " \
        "for #{resource_class.name}=#{resource_noid}"
      )
    end
end
