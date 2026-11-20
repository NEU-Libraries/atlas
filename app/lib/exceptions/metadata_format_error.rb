# frozen_string_literal: true

module Exceptions
  # A preview request names no format Atlas renders, or sends no draft. The
  # code is the 422 `error` discriminator, so treat it as a wire contract.
  class MetadataFormatError < StandardError
    attr_reader :code

    def initialize(code, message = nil)
      @code = code
      super(message || code.to_s)
    end
  end
end
