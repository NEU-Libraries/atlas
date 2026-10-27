# frozen_string_literal: true

module Exceptions
  # A fixity check result is malformed, or names an object or version that does
  # not exist. Raised before anything is written, and the codes are the 422
  # `error` discriminator, so treat them as a wire contract.
  class FixityCheckError < StandardError
    attr_reader :code

    def initialize(code, message = nil)
      @code = code
      super(message || code.to_s)
    end
  end
end
