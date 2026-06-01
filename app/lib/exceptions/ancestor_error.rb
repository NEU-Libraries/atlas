# frozen_string_literal: true

module Exceptions
  # Raised when walking a resource's ancestry encounters a repeated NOID —
  # i.e. the structural tree has been corrupted into a cycle (A → B → A).
  # The collection/community backbone is meant to be a strict tree, so this
  # should never happen in practice; the guard exists to fail loudly instead
  # of recursing forever (V1 carried the same defense; V2's walk had none).
  class AncestorError < StandardError; end
end
