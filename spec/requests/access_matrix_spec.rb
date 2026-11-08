# frozen_string_literal: true

require 'rails_helper'

# Sends every row of AccessMatrix (spec/support/matrices/access_matrix.rb) as
# every tier, in every state, and checks the status, the bytes and the markers.
# The inventory examples fail when a route has no row, so a new route cannot
# ship without someone deciding what a tombstone or a private ACL means for it.
# See docs/testing.md.

# default_auth: false — the global admin default is an operator and would be
# served everything.
RSpec.describe 'Access matrix', type: :request, default_auth: false do
  include_context 'access matrix callers'

  let(:markers) { AccessMatrix::MARKERS }
  let(:bytes)   { File.binread(MatrixWorld::FIXTURE) }
  let(:world)   { MatrixWorld.new }

  after { Atlas.persister.wipe! }

  def apply!(state)
    return withhold_bytes!(state) if AccessMatrix::BYTES_WITHHELD.include?(state)

    world.apply!(state)
  end

  # The embargo and the tier reservation both sit on the Work, which keeps its
  # public ACL. The fixture file is generic, so the generic tier gates it.
  def withhold_bytes!(state)
    resource = Work.find(world.work.noid)
    if state == :embargoed
      resource.embargo_release_date = 1.year.from_now
    else
      resource.derivative_permissions = { generic: [AccessMatrix::RESERVED_GROUP] }.to_json
    end
    Atlas.persister.save(resource: resource)
  end

  # A pinned version is looked up, as an operator, through the listing beside
  # it, before the state is applied.
  def path_for(route, subject)
    path = route.path.spec.to_s.sub('(.:format)', '')
    path = path.sub(':id', world.public_send(subject).noid) if subject
    return path unless path.include?(':version_id')

    get path.sub(%r{/:version_id.*}, ''), headers: headers_for(:admin)
    path.sub(':version_id', response.parsed_body['versions'].first['version_id'].to_s)
  end

  def probes
    MatrixWorld.routes.filter_map do |route, key|
      options = AccessMatrix::MATRIX.dig(key, 1) || {}
      next unless AccessMatrix::MATRIX.key?(key) && route.verb == (options[:post] ? 'POST' : 'GET')

      subject = subject_for(route, options)
      [key, subject, path_for(route, subject)]
    end
  end

  # The resource a row's :id names, or nil for a route that takes none.
  def subject_for(route, options)
    return options[:on] if options[:on]

    spec = route.path.spec.to_s
    AccessMatrix::SEGMENT_SUBJECTS[spec.split('/')[1]] if spec.include?(':id')
  end

  def request!(key, path, tier)
    options = AccessMatrix::MATRIX.dig(key, 1) || {}
    return get(path, params: options[:query], headers: headers_for(tier)) unless options[:post]

    ids = %i[work file_set blob delegate empty_collection sub_community].map { |s| world.public_send(s).noid }
    post path, params: { ids: ids }, headers: headers_for(tier)
  end

  # A refusal carries no bytes, and a byte route that serves carries them whole.
  def bytes_wrong?(options)
    served = response.body.b
    return served != bytes if response.status == 200 && options[:bytes]

    response.status != 200 && served.include?(bytes)
  end

  def leaked_markers(state, tier)
    return [] if AccessMatrix::OPERATORS.include?(tier)

    body = response.body.b
    AccessMatrix::WITHHELD.fetch(state).select { |s| markers[s] && body.include?(markers[s]) }
  end

  # The cell's miss, or nil when the response is what the row says.
  def check(state, key, subject, tier)
    policy, options = AccessMatrix::MATRIX[key]
    expected = AccessMatrix.expected(state, tier, subject, policy, options || {})
    faults = [(', bytes wrong' if bytes_wrong?(options || {}))]
    leaks = leaked_markers(state, tier)
    faults << ", carries #{leaks.join(', ')}" if leaks.any?
    return if response.status == expected && faults.compact.empty?

    "#{key} as #{tier}: expected #{expected}, got #{response.status}#{faults.join}"
  end

  AccessMatrix::STATES.each do |state|
    it "answers every route as its row says when #{state.to_s.tr('_', ' ').sub(/\Alive/, 'all is live')}" do
      world.build!
      routes = probes
      apply!(state)

      seen = Set.new
      misses = routes.flat_map do |key, subject, path|
        AccessMatrix::TIERS.filter_map do |tier|
          request!(key, path, tier)
          markers.each { |s, marker| seen << s if response.body.b.include?(marker) }
          check(state, key, subject, tier)
        end
      end

      expect(misses).to be_empty, "#{misses.size} cells differ:\n  #{misses.join("\n  ")}"
      # Proves the marker check can fire: every marker reaches some response.
      expect(seen).to match_array(markers.keys) if state == :live
    end
  end

  describe 'the route inventory' do
    it 'gives every read route a row or a reason' do
      reads = MatrixWorld.routes.select { |route, _| route.verb == 'GET' }.map(&:last).uniq
      unclassified = reads - AccessMatrix::MATRIX.keys - AccessMatrix::UNSCOPED.keys
      expect(unclassified).to be_empty,
                              "Add a row to MATRIX, or a reason to UNSCOPED, for: #{unclassified.join(', ')}"
    end

    it 'names no route that the application no longer draws' do
      drawn = MatrixWorld.routes.map(&:last)
      expect(AccessMatrix::MATRIX.keys + AccessMatrix::UNSCOPED.keys - drawn).to be_empty
    end
  end
end
