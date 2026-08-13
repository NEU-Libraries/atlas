# frozen_string_literal: true

module Exceptions
  # Raised when adding a Work association fails validation (unknown
  # relationship type, target not found, target not a Work, target is the
  # Work itself, or either end tombstoned). Carries a stable machine-readable
  # `code` that ApplicationController renders as the 422 `error`
  # discriminator — treat the codes as a wire contract atlas_rb can key typed
  # errors on.
  class WorkAssociationError < StandardError
    attr_reader :code

    def initialize(code, message = nil)
      @code = code
      super(message || code.to_s)
    end
  end
end
