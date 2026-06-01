# frozen_string_literal: true

module Exceptions
  # Raised when adding/removing a Work's linked membership fails validation
  # (target not found, target not a Collection, target tombstoned, work
  # tombstoned, or the Work is already a structural member of the target).
  # Carries a stable machine-readable `code` that ApplicationController
  # renders as the 422 `error` discriminator — treat the codes as a wire
  # contract atlas_rb can key typed errors on.
  class LinkedMemberError < StandardError
    attr_reader :code

    def initialize(code, message = nil)
      @code = code
      super(message || code.to_s)
    end
  end
end
