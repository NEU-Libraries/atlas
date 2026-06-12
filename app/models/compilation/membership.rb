# frozen_string_literal: true

class Compilation
  # Shared shape of the three Compilation membership join models. Each row
  # stores a resource noid; on create the noid must resolve to the model's
  # EXPECTED_RESOURCE_TYPE — this is where the "Works and Collections only,
  # no Communities / top node" invariant is enforced server-side. One Valkyrie
  # resolution per add is an acceptable cost (adds are rare, reads never
  # re-resolve). Duplicate rows are blocked by the DB uniqueness constraint,
  # not a model validation — the controller add path is find_or_create_by,
  # so the constraint is a belt-and-suspenders guard, not a 422 surface.
  module Membership
    extend ActiveSupport::Concern

    included do
      belongs_to :compilation

      validates :resource_noid, presence: true
      validate :resource_noid_resolves_to_expected_type, on: :create
    end

    private

      def resource_noid_resolves_to_expected_type
        expected = self.class::EXPECTED_RESOURCE_TYPE
        return if resolved_resource.is_a?(expected)

        errors.add(:resource_noid, "must resolve to a #{expected.name}")
      end

      def resolved_resource
        Atlas.query.find_by_alternate_identifier(alternate_identifier: resource_noid.to_s)
      rescue Valkyrie::Persistence::ObjectNotFoundError
        nil
      end
  end
end
