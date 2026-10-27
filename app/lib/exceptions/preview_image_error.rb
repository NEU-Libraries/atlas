# frozen_string_literal: true

module Exceptions
  # The preview image's size or placeholder is malformed, or sent without the
  # preview URI it describes. Raised before anything is persisted, and the
  # codes are the 422 `error` discriminator, so treat them as a wire contract.
  class PreviewImageError < StandardError
    attr_reader :code

    def initialize(code, message = nil)
      @code = code
      super(message || code.to_s)
    end
  end
end
