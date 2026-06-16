# frozen_string_literal: true

module Exceptions
  # Raised on the verify-on-ingest path when an upload carries an
  # `expected_digest` that the streamed bytes don't satisfy. Carries a stable
  # machine-readable `code` that ApplicationController renders as the 422
  # `error` discriminator — atlas_rb can key typed errors on it, so treat the
  # codes (`fixity_mismatch`, `unsupported_digest_algorithm`) as a wire
  # contract. Raised *before* any resource is persisted, so a rejected transfer
  # leaves no orphaned Blob/FileSet behind.
  class FixityMismatch < StandardError
    attr_reader :code

    def initialize(code, message = nil)
      @code = code
      super(message || code.to_s)
    end
  end
end
