# frozen_string_literal: true

module Exceptions
  # Raised by TombstoneGate when a caller below the operator tiers asks for the
  # bytes or the file list of a tombstoned resource. ApplicationController
  # renders it as 410 `tombstoned`, naming the resource whose tombstone applies.
  class Tombstoned < StandardError
    CODE = 'tombstoned'

    attr_reader :source

    def initialize(source)
      @source = source
      super("#{source.class.name.downcase} #{source.noid} is tombstoned")
    end
  end
end
