# frozen_string_literal: true

module Exceptions
  # Raised by ParentScopedCreate when the named container is tombstoned.
  # Rescued there into the 422 `tombstoned_parent` that restore and re-parent
  # also answer.
  class TombstonedParent < StandardError
    CODE = 'tombstoned_parent'

    def initialize(message = nil)
      super(message || 'cannot create inside a tombstoned container')
    end
  end
end
