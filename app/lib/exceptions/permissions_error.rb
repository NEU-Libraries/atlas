# frozen_string_literal: true

module Exceptions
  # Raised by PermissionsWriteGuard when an incoming ACL breaks a rights
  # invariant: today the only one is a read audience wider than the structural
  # parent's (`visibility_exceeds_parent`). Carries a stable machine-readable
  # `code` that ApplicationController renders as the 422 `error` discriminator —
  # treat the codes as a wire contract atlas_rb can key typed errors on.
  class PermissionsError < StandardError
    attr_reader :code

    def initialize(code, message = nil)
      @code = code
      super(message || code.to_s)
    end
  end
end
