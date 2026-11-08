# frozen_string_literal: true

# The cell rule for a matrix with no resource tree: Sets, People, accounts and
# the service endpoints. A row names the tiers it admits and the status a
# permitted call answers, and the floors apply in the order
# ApplicationController applies them. See docs/testing.md.
#
# A row's options:
#   allowed:  the tiers it admits, or a lambda of (state, tier)
#   ok:       the status a permitted call answers (default 200)
#   write:    the read-only token and the maintenance window refuse it
#   maintenance_exempt: the one write the window must let through, or it
#             could never be closed
#   no_auth:  the action skips require_auth, so no credential is refused
#   path:     a lambda of the subjects, giving the path's named segments
#   params:   a lambda of (subjects, state), giving the body or query
#   json:     send params as a JSON body
#   fresh:    a success damages the subjects, so the next cell rebuilds them
module FlatMatrix
  def self.expected(state, tier, options)
    return options.fetch(:ok, 200) if options[:no_auth]
    return 403 if tier == :obo_refused

    floor(state, tier, options) || (allowed?(state, tier, options) ? options.fetch(:ok, 200) : 403)
  end

  # The maintenance window and the read-only token, which refuse a write
  # before any grant is read.
  def self.floor(state, tier, options)
    return nil unless options[:write]
    return 503 if state == :maintenance && !options[:maintenance_exempt]

    403 if tier == :read_only
  end

  def self.allowed?(state, tier, options)
    allowed = options.fetch(:allowed)
    allowed.respond_to?(:call) ? allowed.call(state, tier) : allowed.include?(tier)
  end
end
