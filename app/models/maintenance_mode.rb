# frozen_string_literal: true

# The repository-wide read-only window, held as a single row. In the DATABASE
# because a deploy would reset an env var, and in ATLAS because a
# Cerberus-held flag is bypassed by any direct API caller. See
# docs/availability.md.
class MaintenanceMode < ApplicationRecord
  # A deploy closes only a deploy-opened window; a human door closes either.
  # That is what stops a finishing deploy closing a window a human opened.
  SOURCES = %w[operator deploy].freeze

  validates :source, inclusion: { in: SOURCES }, allow_nil: true
  validates :retry_after, numericality: { only_integer: true, greater_than: 0 }

  # authorize! consults the flag on EVERY authorized action, so an uncached
  # read would add a query per action. CurrentAttributes resets between
  # requests, so another process's window is seen on the next request.
  class Cache < ActiveSupport::CurrentAttributes
    attribute :record
  end

  def self.current
    Cache.record ||= first || create!
  end

  def self.read_only? = current.read_only?

  def self.retry_after = current.retry_after

  # Re-opening re-stamps the source, so a deploy starting inside an operator
  # window takes ownership rather than having its own close refused.
  def self.open!(source:, message: nil, retry_after: nil)
    attrs = { read_only: true, source: source.to_s, message: message, since: Time.current }
    attrs[:retry_after] = retry_after if retry_after
    current.tap { |row| row.update!(attrs) }
  end

  # A refused close returns the UNCHANGED row, so the caller sees the real
  # state rather than a false "closed".
  def self.close!(source:)
    row = current
    return row unless row.read_only?
    return row if source.to_s == 'deploy' && row.source == 'operator'

    row.tap { |r| r.update!(read_only: false, source: nil, message: nil, since: nil) }
  end
end
