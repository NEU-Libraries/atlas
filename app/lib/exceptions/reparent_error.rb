# frozen_string_literal: true

module Exceptions
  # Raised by Reparenter when a re-parent request fails structural validation
  # (bad parent type, cycle, tombstoned node/parent, missing required parent).
  # Carries a stable machine-readable `code` that ApplicationController renders
  # as the 422 `error` discriminator — atlas_rb can key typed errors on it, so
  # treat the codes as a wire contract.
  class ReparentError < StandardError
    attr_reader :code

    def initialize(code, message = nil)
      @code = code
      super(message || code.to_s)
    end
  end
end
