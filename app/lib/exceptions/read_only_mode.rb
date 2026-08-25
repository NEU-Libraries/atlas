# frozen_string_literal: true

module Exceptions
  # Raised by ApplicationController#authorize! when a write-shaped action is
  # attempted while the repository-wide maintenance window is open.
  #
  # Deliberately NOT CanCan::AccessDenied: a 403 is a statement about the
  # caller's rights, and atlas_rb maps it to AtlasRb::ForbiddenError, which
  # Cerberus renders as a permission-denied page. During a maintenance window
  # that is a lie — the caller's rights are fine, the repository is closed.
  # This rescues into a 503 carrying the `read_only_mode` discriminator.
  class ReadOnlyMode < StandardError
    CODE = 'read_only_mode'

    def initialize(message = nil)
      super(message || 'Atlas is in maintenance mode; writes are refused')
    end
  end
end
