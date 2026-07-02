# frozen_string_literal: true

module Exceptions
  # Raised when a per-tier derivative-visibility policy fails validation: an
  # unknown tier key (`unknown_tier`), a tier more visible than its Work
  # (`tier_exceeds_resource`), or a higher-resolution tier more visible than a
  # lower one (`tier_ordering_violation`). Carries a stable machine-readable
  # `code` that ApplicationController renders as the 422 `error` discriminator —
  # treat the codes as a wire contract atlas_rb can key typed errors on.
  class DerivativePermissionsError < StandardError
    attr_reader :code

    def initialize(code, message = nil)
      @code = code
      super(message || code.to_s)
    end
  end
end
