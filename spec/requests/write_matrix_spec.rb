# frozen_string_literal: true

require 'rails_helper'

# Sends every row of WriteMatrix (spec/support/matrices/write_matrix.rb) as
# every tier, in every state. A refused cell must also leave the repository
# unchanged. See docs/testing.md.

# default_auth: false — the global admin default would be served everything.
RSpec.describe 'Write matrix', type: :request, default_auth: false do
  include_context 'access matrix callers'

  attr_reader :world

  after { Atlas.persister.wipe! }

  # One drawn route per row. A PUT twin of a PATCH answers the same gate, so
  # the PATCH is the one probed.
  def route_for(row)
    key = WriteMatrix.key_of(row)
    routes = AccessMatrixFixtures.routes.select { |route, k| k == key && route.verb != 'GET' }.map(&:first)
    routes.find { |route| route.verb != 'PUT' } || routes.first
  end

  def path_for(route, options)
    path = route.path.spec.to_s.sub('(.:format)', '')
    path = path.sub(':id', subject_for(options).noid) if path.include?(':id')
    (options[:path]&.call(world) || {}).reduce(path) { |p, (name, value)| p.sub(":#{name}", value.to_s) }
  end

  def request!(row, tier)
    _, options = WriteMatrix::MATRIX.fetch(row)
    route   = route_for(row)
    headers = headers_for(tier)
    # Acting as the Work's depositor is half of the :system grant.
    if tier == :system && options[:system_scoped]
      headers = headers.merge('On-Behalf-Of' => "NUID #{world.work.depositor}")
    end
    params = options[:params]&.call(world) || {}
    send(route.verb.downcase, path_for(route, options), params: params, headers: headers,
                                                        as: (options[:json] ? :json : nil))
  end

  # What a refused write must leave as it found it: every resource's last
  # write, the audit rows and the idempotency keys.
  def fingerprint
    [AuditEvent.count, IdempotencyKey.count,
     Atlas.query.find_all.map { |resource| [resource.id.to_s, resource.updated_at.to_f] }.sort]
  end

  def build!(state)
    @world = AccessMatrixFixtures.new.build!
    # Built now, so the first cell that names them does not count their
    # creation as a write it made.
    [world.other_work, world.featured_collection]
    world.apply!(state) unless state == :maintenance
  end

  def subject_for(options) = (options[:fresh] && @scratch) || world.public_send(options[:on])

  # The fixtures start every state sealed, so any envelope that lags Postgres
  # after a permitted write is one that write left behind. A refused write
  # changes nothing (the fingerprint holds it), so it needs no scan.
  def envelope_fault
    return nil unless response.status.between?(200, 299)

    lagging = lagging_envelopes(since: world.sealed)
    world.seal!(lagging)
    return nil if lagging.empty?

    ", and left the envelope behind: #{lagging.map { |r, lag| "#{r.class.name} #{r.noid} #{lag}" }.join(', ')}"
  end

  def check(state, row, tier)
    policy, options = WriteMatrix::MATRIX.fetch(row)
    expected = WriteMatrix::Cell.new(state, tier, policy, options).expected
    before = fingerprint unless expected.between?(200, 299)
    request!(row, tier)
    fault = ', and changed the repository' if before && fingerprint != before
    fault = "#{fault}#{envelope_fault}".presence
    return if response.status == expected && fault.nil?

    "#{row} as #{tier}: expected #{expected}, got #{response.status}#{fault}"
  end

  # A fresh row writes to a throwaway copy of its subject, in the same state,
  # and takes a new one after each success. The shared world is never damaged,
  # so it is built once per state.
  def run_state(state)
    WriteMatrix::MATRIX.flat_map do |row, (_, options)|
      @scratch = nil
      WriteMatrix::TIERS.filter_map do |tier|
        @scratch ||= world.scratch(options[:on], state) if options[:fresh]
        miss = check(state, row, tier)
        @scratch = nil if response.status.between?(200, 299)
        miss
      end
    end
  end

  WriteMatrix::STATES.each do |state|
    it "answers every write as its row says when #{state.to_s.tr('_', ' ').sub(/\Alive/, 'all is live')}" do
      build!(state)
      MaintenanceMode.open!(source: 'operator') if state == :maintenance

      misses = run_state(state)
      expect(misses).to be_empty, "#{misses.size} cells differ:\n  #{misses.join("\n  ")}"
    end
  end

  # Every refusal on a private Work must be the write gate's 403, never a 404
  # that hides whether the Work exists. The permitted cells answer as in the
  # live state, so only the refusals run here.
  it 'refuses every write on a private Work with 403' do
    build!(:private)
    misses = WriteMatrix::MATRIX.flat_map do |row, (policy, options)|
      WriteMatrix::TIERS.filter_map do |tier|
        next if WriteMatrix::Cell.new(:private, tier, policy, options).expected.between?(200, 299)

        check(:private, row, tier)
      end
    end
    expect(misses).to be_empty, "#{misses.size} cells differ:\n  #{misses.join("\n  ")}"
  end
end
