# frozen_string_literal: true

# The repository-wide read-only window, held as a single row.
#
# The flag lives in the database rather than an environment variable because a
# deploy replaces the containers: an env var would be reset by the very deploy
# that set it. It lives in Atlas rather than Cerberus because a Cerberus-held
# flag is bypassed by any direct API caller, including a personal access token
# minted by POST /nuid.
#
# `source` names which door opened the window, and is load-bearing rather than
# decoration. Three doors open the same window — the Cerberus admin hub, the
# `maintenance:` rake task, and the deploy orchestrator — and a deploy that
# finishes must not close a window a human opened by hand. See .close.
class MaintenanceMode < ApplicationRecord
  # A deploy closes only a deploy-opened window. `operator` is the human doors
  # (the admin hub and the rake task); a human may close either, because a human
  # is deciding.
  SOURCES = %w[operator deploy].freeze

  validates :source, inclusion: { in: SOURCES }, allow_nil: true
  validates :retry_after, numericality: { only_integer: true, greater_than: 0 }

  # Per-request memo. ApplicationController#authorize! consults the flag on
  # every authorized action, so an uncached read would add a query per action.
  # CurrentAttributes resets itself between requests, so a window opened by
  # another process is seen on the next request rather than at process restart.
  class Cache < ActiveSupport::CurrentAttributes
    attribute :record
  end

  # The singleton row, created on first read so callers never handle a nil.
  def self.current
    Cache.record ||= first || create!
  end

  def self.read_only? = current.read_only?

  def self.retry_after = current.retry_after

  # Open the window. Re-opening an already-open window re-stamps it with the
  # new source and message, so a deploy that starts inside an operator window
  # takes ownership of it — the alternative would let the deploy's own close
  # be refused by a source it never set.
  def self.open!(source:, message: nil, retry_after: nil)
    attrs = { read_only: true, source: source.to_s, message: message, since: Time.current }
    attrs[:retry_after] = retry_after if retry_after
    current.tap { |row| row.update!(attrs) }
  end

  # Close the window, if this door is allowed to. A deploy may not close an
  # operator-opened window; it leaves the window standing and returns the
  # unchanged row, so the caller sees the real state rather than a false
  # "closed". A human door closes either.
  def self.close!(source:)
    row = current
    return row unless row.read_only?
    return row if source.to_s == 'deploy' && row.source == 'operator'

    row.tap { |r| r.update!(read_only: false, source: nil, message: nil, since: nil) }
  end
end
