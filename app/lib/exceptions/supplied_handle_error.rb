# frozen_string_literal: true

module Exceptions
  # Raised when a create brings a handle Atlas will not record: a malformed
  # value (422 invalid_handle) or one another Work already holds (409
  # handle_taken). The `code` is a wire contract atlas_rb can key typed errors
  # on, like the other create-time refusals.
  class SuppliedHandleError < StandardError
    STATUSES = { invalid_handle: :unprocessable_content, handle_taken: :conflict }.freeze

    attr_reader :code

    def initialize(code, message = nil)
      @code = code
      super(message || code.to_s)
    end

    def status
      STATUSES.fetch(code)
    end
  end
end
