# frozen_string_literal: true

# Helpers for replay-safe create endpoints: Cerberus's per-record jobs send an
# Idempotency-Key so an Atlas commit followed by a Cerberus crash does not
# produce a duplicate on retry. See docs/write-safety.md.
#
# Controllers wire the three helpers explicitly from the create action rather
# than through a before_action, so a first-time reader sees the whole flow in
# one place.
module IdempotentCreate
  extend ActiveSupport::Concern

  private

    # Scoped per resource CLASS, not per action: that lets one batch-load row
    # use one key for the Work and again for its Blob, but means a caller
    # sending one key to both POST /files and PATCH /files/:id sees the second
    # as a replay of the first.
    def find_idempotency_record(resource_class)
      key = request.headers['Idempotency-Key']
      return if key.blank? || @current_user.nil?

      IdempotencyKey.find_by(
        user_id: @current_user.id, key: key,
        resource_type: resource_class.name
      )
    end

    # The FileSet attach replay passes :update, because the idempotent
    # operation there is a PATCH rather than a POST.
    def render_idempotent_resource(resource, view: :create)
      return head(:gone) if resource.nil?
      return render(:show, status: :gone) if resource.tombstoned

      render view
    end

    # Bookkeeping NEVER fails the request: the resource is already in
    # Postgres, Solr and OCFL by now, so raising would report a create that
    # landed as an error and the caller would retry it into a second copy. A
    # transaction would not help -- the Solr and OCFL writes are outside it.
    def record_idempotency_key!(resource_noid, resource_class)
      key = request.headers['Idempotency-Key']
      return if key.blank? || @current_user.nil?

      IdempotencyKey.create!(
        user: @current_user, key: key,
        resource_type: resource_class.name,
        resource_noid: resource_noid
      )
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # A failure on anything but the key is our bug, not a race: stay loud.
      raise if e.is_a?(ActiveRecord::RecordInvalid) && e.record.errors[:key].blank?

      Rails.logger.warn(
        "[IdempotentCreate] lost the race recording key=#{key} " \
        "for #{resource_class.name}=#{resource_noid}"
      )
    end
end
