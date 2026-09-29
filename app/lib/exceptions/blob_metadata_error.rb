# frozen_string_literal: true

module Exceptions
  # A Blob's `language` or `track_label` is malformed. Raised before anything is
  # persisted, and the codes (`invalid_language`, `invalid_track_label`) are
  # the 422 `error` discriminator, so treat them as a wire contract.
  class BlobMetadataError < StandardError
    attr_reader :code

    def initialize(code, message = nil)
      @code = code
      super(message || code.to_s)
    end
  end
end
