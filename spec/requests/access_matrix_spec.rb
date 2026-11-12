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
  let(:bytes)   { File.binread(AccessMatrixFixtures::FIXTURE) }
  let(:world)   { AccessMatrixFixtures.new }

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
    path = path.sub(':pid', world.public_send(subject).legacy_pid) if subject && path.include?(':pid')
    return path unless path.include?(':version_id')

    get path.sub(%r{/:version_id.*}, ''), headers: headers_for(:admin)
    path.sub(':version_id', response.parsed_body['versions'].first['version_id'].to_s)
  end

  # One probe per row; a route with a second row (an `@variant`) is sent twice.
  def probes
    AccessMatrixFixtures.routes.flat_map do |route, key|
      AccessMatrix::MATRIX.select { |row, _| row.split('@').first == key }.filter_map do |row, (_, options)|
        options ||= {}
        next unless route.verb == (options[:post] ? 'POST' : 'GET')

        subject = subject_for(route, options)
        [row, subject, path_for(route, subject)]
      end
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

  # A tombstone withholds below the operator tiers; an embargo withholds a
  # gated URL from everyone without an edit grant or the bypass.
  def leaked_markers(state, tier)
    withheld = AccessMatrix::OPERATORS.include?(tier) ? [] : AccessMatrix::WITHHELD.fetch(state)
    withheld += AccessMatrix::URI_WITHHELD.fetch(state, []) unless MatrixTree::URI_AUDIENCE.include?(tier)
    body = response.body.b
    withheld.select { |s| markers[s] && body.include?(markers[s]) }
  end

  def told_guest(tier)
    return [] unless tier == :guest

    body = response.body.b
    MatrixTree::GUEST_UNTOLD.select { |secret| body.include?(secret) }
  end

  # What is wrong with the body, whatever the status.
  def faults(state, tier, options)
    leaks = leaked_markers(state, tier)
    told = told_guest(tier)
    [(', bytes wrong' if bytes_wrong?(options)), (", carries #{leaks.join(', ')}" if leaks.any?),
     (", tells a guest #{told.join(', ')}" if told.any?)].compact
  end

  # The cell's miss, or nil when the response is what the row says.
  def check(state, key, subject, tier)
    policy, options = AccessMatrix::MATRIX[key]
    expected = AccessMatrix.expected(state, tier, subject, policy, options || {})
    faults = faults(state, tier, options || {})
    return if response.status == expected && faults.empty?

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
end
