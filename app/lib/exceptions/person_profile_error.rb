# frozen_string_literal: true

module Exceptions
  # A Person's `display_name`, `bio` or `orcid` is malformed. Raised before
  # anything is persisted, and the codes (`blank_display_name`, `invalid_bio`,
  # `invalid_orcid`) are the 422 `error` discriminator, so treat them as a wire
  # contract.
  class PersonProfileError < StandardError
    attr_reader :code

    def initialize(code, message = nil)
      @code = code
      super(message || code.to_s)
    end
  end
end
