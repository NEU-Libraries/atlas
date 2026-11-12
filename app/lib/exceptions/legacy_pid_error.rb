# frozen_string_literal: true

module Exceptions
  # Raised when a create brings a v1 pid Atlas will not record: a malformed
  # value (422 invalid_legacy_pid) or one another resource holds (409
  # legacy_pid_taken). On a 409, holder_id names the holder, so a migration
  # that crashed between the create and its own bookkeeping can recover the
  # NOID without parsing the message.
  class LegacyPidError < StandardError
    STATUSES = { invalid_legacy_pid: :unprocessable_content, legacy_pid_taken: :conflict }.freeze

    attr_reader :code, :holder_id

    def initialize(code, message = nil, holder_id: nil)
      @code      = code
      @holder_id = holder_id
      super(message || code.to_s)
    end

    def status
      STATUSES.fetch(code)
    end
  end
end
