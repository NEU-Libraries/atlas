# frozen_string_literal: true

require 'rails_helper'

# What every read route answers, for each state a resource can be in and each
# caller tier. A route is a row, and its policy says what each cell should get.
# The inventory examples fail when a route has no row, so a new route cannot
# ship without someone deciding what a tombstone or a private ACL means for it.
# See docs/testing.md.
#
# rubocop:disable Metrics/ModuleLength -- the rows are one table, and splitting
# it would scatter a single decision across modules.
module AccessMatrix
  # The states that withhold a Work's file bytes but not its record: metadata
  # stays public under an embargo and under a tier reservation.
  BYTES_WITHHELD = %i[embargoed tier_gated].freeze

  STATES    = (MatrixWorld::STATES + BYTES_WITHHELD).freeze
  TIERS     = %i[guest standard editor delegate admin].freeze
  OPERATORS = MatrixWorld::OPERATORS
  WITHHELD  = MatrixWorld::WITHHELD.merge(BYTES_WITHHELD.index_with { [] }).freeze
  PRIVATE_SUBJECTS = MatrixWorld::PRIVATE_SUBJECTS
  MARKERS = MatrixWorld::MARKERS

  # A group no tier here belongs to, so the tier_gated state admits only :admin.
  RESERVED_GROUP = 'northeastern:drs:matrix:reserved'

  # The editor holds an edit grant on the Work, which is what lets it past a
  # private ACL. A tombstone leaves the ACL public.
  Cell = Struct.new(:state, :tier, :subject) do
    def readable? = state != :private || PRIVATE_SUBJECTS.exclude?(subject) || %i[editor admin].include?(tier)
    def operator? = OPERATORS.include?(tier)
    def tombstoned? = WITHHELD.fetch(state).include?(subject)
    def withheld? = tombstoned? && !operator?
    # No test tier is staff, so only :admin passes the embargo bypass.
    def bytes_withheld? = BYTES_WITHHELD.include?(state) && subject == :blob && tier != :admin

    def bytes_status
      return 410 if withheld?

      bytes_withheld? ? 403 : 200
    end

    # The per-resource read gate answers first, so a caller who may not read
    # the resource learns nothing about its tombstone.
    def gated = readable? ? yield : 403
  end

  POLICIES = {
    read:          ->(c) { c.gated { 200 } },
    redirect:      ->(c) { c.gated { 302 } },
    # The record of a tombstoned resource answers 410 to everyone: the full
    # record to an operator, a stub or the tombstoned envelope to the rest.
    record:        ->(c) { c.gated { c.tombstoned? ? 410 : 200 } },
    # The bytes, the file lists and the metadata are withheld below the
    # operator tiers.
    withheld:      ->(c) { c.gated { c.withheld? ? 410 : 200 } },
    # A Work's file bytes: withheld by a tombstone, then by an embargo or a
    # tier reservation, in the order the byte routes check them.
    bytes:         ->(c) { c.gated { c.bytes_status } },
    # A class-wide operator verb makes no per-resource read decision.
    operator:      ->(c) { c.operator? ? 200 : 403 },
    operator_read: ->(c) { c.operator? ? c.gated { 200 } : 403 },
    admin:         ->(c) { c.tier == :admin ? 200 : 403 },
    # A list or a container no state here tombstones: always served, and the
    # marker check alone says whether it leaks a withheld subject.
    open:          ->(_) { 200 }
  }.freeze

  # 'controller#action' => [policy, options]. `on:` names the subject the :id
  # resolves to when the path's first segment does not. `bytes:` marks a route
  # that must serve the file's bytes whole whenever it answers 200.
  MATRIX = {
    'works#show'                 => [:record],
    'works#mods'                 => [:withheld],
    'works#mets'                 => [:withheld],
    'works#associations'         => [:withheld],
    'works#linked_members'       => [:withheld],
    'works#assets'               => [:withheld],
    'works#file_sets'            => [:withheld],
    'works#file_revisions'       => [:withheld],
    'works#tombstoned_assets'    => [:operator],
    'works#health_check'         => [:operator],
    'works#index'                => [:admin],
    'darwin_core#show'           => [:withheld],
    'darwin_core#versions'       => [:operator],
    'darwin_core#version'        => [:withheld],
    'file_sets#show'             => [:record],
    'file_sets#mets'             => [:withheld],
    'file_sets#index'            => [:admin],
    'blobs#show'                 => [:record],
    'blobs#content'              => [:bytes, { bytes: true }],
    'blobs#version_content'      => [:bytes, { bytes: true }],
    # NOIDs and tombstone flags only: it is how a client learns which ancestor
    # withholds a file.
    'blobs#ancestry'             => [:read],
    'blobs#versions'             => [:operator],
    'blobs#index'                => [:admin],
    'delegates#show'             => [:record],
    'resources#show'             => [:redirect],
    'resources#mods'             => [:withheld],
    'resources#mods_versions'    => [:operator],
    'resources#mods_version'     => [:withheld],
    'resources#permissions'      => [:withheld],
    'resources#descendant_works' => [:open, { on: :collection }],
    'resource_children#show'     => [:operator, { on: :collection }],
    'audit_events#index'         => [:operator_read],
    'index_documents#show'       => [:operator_read],
    'search_explanations#show'   => [:operator_read, { query: { q: 'title' } }],
    'search#index'               => [:open, { query: { q: MARKERS.values.join(' OR ') } }],
    # A POST that reads: the batch resolver, asked for every subject at once.
    'resources#find_many'        => [:open, { post: :all_subjects }],
    'collections#show'           => [:record, { on: :empty_collection }],
    'collections#mods'           => [:withheld, { on: :empty_collection }],
    'collections#children'       => [:record, { on: :empty_collection }],
    'communities#show'           => [:record, { on: :sub_community }],
    'communities#mods'           => [:withheld, { on: :sub_community }],
    'communities#children'       => [:record, { on: :sub_community }]
  }.freeze

  # Reads keyed on something other than a resource in this tree. Each names
  # where its gate is covered instead.
  UNSCOPED = {
    'compilations#index'       => 'a Set, not a resource: spec/requests/compilations_spec.rb',
    'compilations#show'        => 'a Set, not a resource: spec/requests/compilations_spec.rb',
    'compilations#contents'    => 'a Set, not a resource: spec/requests/compilations_spec.rb',
    'communities#index'        => 'a roll of containers: spec/requests/index_read_gate_spec.rb',
    'collections#index'        => 'a roll of containers: spec/requests/index_read_gate_spec.rb',
    'people#index'             => 'a Person, not a resource: spec/requests/people_spec.rb',
    'people#show'              => 'a Person, not a resource: spec/requests/people_spec.rb',
    'resources#preview'        => 'renders posted MODS and reads no resource',
    'blobs#find_many_versions' => 'class-wide :read_versions: spec/requests/binary_versions_spec.rb',
    'fixity_checks#due'        => 'the fixity checker only: spec/requests/fixity_checks_spec.rb',
    'oai#index'                => 'the metadata harvest, which withholds a tombstoned record: spec/requests/oai_spec.rb',
    'docs#show'                => 'the API documentation',
    'maintenance#show'         => 'the maintenance flag',
    'maintenance#reset'        => 'the development data reset',
    'health#show'              => 'service health',
    'metrics#latency'          => 'operator latency figures: spec/requests/metrics_spec.rb',
    'users/tokens#show'        => "the caller's own account",
    'users#index'              => 'accounts: spec/requests/users_spec.rb',
    'users#show'               => 'accounts: spec/requests/users_spec.rb',
    'users#accounts'           => 'accounts: spec/requests/user_accounts_spec.rb'
  }.freeze

  # The subject a path's first segment names, absent an `on:`.
  SEGMENT_SUBJECTS = {
    'works' => :work, 'file_sets' => :file_set, 'files' => :blob, 'delegates' => :delegate,
    'resources' => :work, 'collections' => :empty_collection, 'communities' => :sub_community
  }.freeze

  def self.routes = MatrixWorld.routes
end
# rubocop:enable Metrics/ModuleLength

# default_auth: false — the global admin default is an operator and would be
# served everything.
RSpec.describe 'Access matrix', type: :request, default_auth: false do
  include_context 'access matrix callers'

  let(:markers) { AccessMatrix::MARKERS }
  let(:bytes)   { File.binread(MatrixWorld::FIXTURE) }
  let(:world)   { MatrixWorld.new(editor_nuid: users[:editor].nuid) }

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
    AccessMatrix.routes.filter_map do |route, key|
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
    expected = AccessMatrix::POLICIES.fetch(policy).call(AccessMatrix::Cell.new(state, tier, subject))
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
      reads = AccessMatrix.routes.select { |route, _| route.verb == 'GET' }.map(&:last).uniq
      unclassified = reads - AccessMatrix::MATRIX.keys - AccessMatrix::UNSCOPED.keys
      expect(unclassified).to be_empty,
                              "Add a row to MATRIX, or a reason to UNSCOPED, for: #{unclassified.join(', ')}"
    end

    it 'names no route that the application no longer draws' do
      drawn = AccessMatrix.routes.map(&:last)
      expect(AccessMatrix::MATRIX.keys + AccessMatrix::UNSCOPED.keys - drawn).to be_empty
    end
  end
end
