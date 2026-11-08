# frozen_string_literal: true

# The two promises a Work makes about its file bytes beyond its read ACL: an
# active embargo withholds them from everyone who may not bypass it, and a
# per-tier gate (Work#derivative_permissions) reserves them to its audience.
# Metadata stays readable under both. See docs/authorization.md.
module WithheldBytesGate
  extend ActiveSupport::Concern

  private

    # Call after the :read check, the nil check and refuse_tombstoned!, and
    # before anything streams: once send_file starts, a refusal cannot replace
    # the body a streaming client has already begun to consume.
    def refuse_withheld_bytes!(blob)
      return if @current_user&.admin? || blob.metadata?

      work = blob.read_authority
      return unless work.is_a?(Work)

      reason = withholding_reason(work, blob)
      raise CanCan::AccessDenied.new("file bytes withheld: #{reason}", :read, blob) if reason
    end

    def withholding_reason(work, blob)
      return 'the Work is under embargo' if work.embargoed? && !embargo_bypass?

      'the file is reserved to another audience' unless tier_audience?(work, blob)
    end

    # Mirrors Cerberus's User#can_bypass_embargo?; the two apps must agree on
    # who sees embargoed bytes.
    def embargo_bypass?
      Array(@current_user&.groups).include?(Permissions::STAFF_EDIT_GROUP)
    end

    # An audience no narrower than the Work's own is the read gate's decision,
    # which an editor of a private Work has already passed. A narrower one
    # counts read groups only, as Cerberus's download gate does: an edit grant
    # does not admit a caller outside the reserved group.
    def tier_audience?(work, blob)
      audience = work.derivative_gate_for(blob)
      return true if TierVisibility.audience_subset?(work.read_groups, audience)

      audience.include?('public') || audience.intersect?(Array(@current_user&.groups))
    end
end
