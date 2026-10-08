# frozen_string_literal: true

module Exceptions
  # A Darwin Core upload breaks a shape rule in DarwinCoreDocument. Raised
  # before anything is written, and the code is the 422 `error` discriminator,
  # so treat it as a wire contract.
  class DarwinCoreError < StandardError
    attr_reader :code

    def initialize(code, message = nil)
      @code = code
      super(message || code.to_s)
    end
  end
end
