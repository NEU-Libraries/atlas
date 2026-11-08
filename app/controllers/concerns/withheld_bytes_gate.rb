# frozen_string_literal: true

# The two promises a Work makes about its file bytes beyond its read ACL: an
# active embargo withholds them from everyone who may not bypass it, and a
# per-tier gate (Work#derivative_permissions) reserves them to its audience.
# Metadata stays readable under both. The embargo also withholds the gated
# image URLs, which the views read through #uri_withheld?. See
# docs/authorization.md.
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
      return 'the Work is under embargo' if embargo_withholds?(work)

      'the file is reserved to another audience' unless tier_audience?(work, blob)
    end

    # True when an active embargo on the Work withholds its bytes from this
    # caller.
    def embargo_withholds?(work)
      work.is_a?(Work) && work.embargoed? && !@current_user&.admin? && !embargo_bypass?
    end

    # The gated image URLs admit an edit grant as well, which the bytes do
    # not: the URL opens nothing without a signature Cerberus issues, and a
    # depositor's derivative job needs it. Keep the two rules apart, so that
    # widening this one never widens the byte gate.
    def uri_withheld?(work)
      embargo_withholds?(work) && !can?(:update, work)
    end

    # Mirrors Cerberus's User#can_bypass_embargo?; the two apps must agree on
    # who sees embargoed bytes.
    def embargo_bypass?
      Array(@current_user&.groups).include?(Permissions::STAFF_EDIT_GROUP)
    end

    # Edit implies read here as everywhere else: an edit grant on the Work
    # (an edit user, an edit group or the depositor; :update grants nothing
    # wider) admits its holder to every tier. Anyone else must be in the
    # tier's audience.
    def tier_audience?(work, blob)
      return true if can?(:update, work)

      audience = work.derivative_gate_for(blob)
      audience.include?('public') || audience.intersect?(Array(@current_user&.groups))
    end
end
