# frozen_string_literal: true

require 'rails_helper'

# What every write route answers, for each state a resource can be in and each
# caller tier: the write half of the access matrix, on the same world. A refused
# cell must also leave the repository unchanged. The inventory examples fail
# when a write route has no row, so a new write cannot ship without someone
# deciding who may make it. See docs/testing.md.
#
# rubocop:disable Metrics/ModuleLength -- the rows are one table, and splitting
# it would scatter a single decision across modules.
module WriteMatrix
  # Least to most privileged, so most rows refuse until their last cells.
  # :system sits beside the human ladder, so it goes after the delegate.
  TIERS  = %i[guest read_only standard editor delegate system admin].freeze
  # A private Work changes no write cell: the editor holds the grant either way
  # and nobody else could write. So it runs its refusals alone, below.
  STATES = (MatrixWorld::STATES - %i[private] + %i[maintenance]).freeze

  # The subjects the editor's grant on the Work reaches.
  EDITOR_SUBJECTS = %i[work file_set blob].freeze

  # The tiers each policy admits, before the floors and the tombstone gate.
  POLICIES = {
    edit:             ->(c) { c.tier == :admin || (c.tier == :editor && EDITOR_SUBJECTS.include?(c.gate_subject)) },
    operator:         ->(c) { MatrixWorld::OPERATORS.include?(c.tier) },
    admin:            ->(c) { c.tier == :admin },
    reindex:          ->(c) { %i[system admin].include?(c.tier) },
    # Only :system and the admin may create in a container nobody else edits.
    create_container: ->(c) { %i[system admin].include?(c.tier) },
    link_member:      ->(c) { c.tier == :admin || (c.tier == :system && c.options[:system_scoped]) }
  }.freeze

  Cell = Struct.new(:state, :tier, :policy, :options) do
    def gate_subject = options.fetch(:on)
    def allowed? = POLICIES.fetch(policy).call(self)
    def operator? = MatrixWorld::OPERATORS.include?(tier)
    def tombstoned?(subject) = MatrixWorld::TOMBSTONED[state] == subject

    # A tombstone refuses a write below the operator tiers, after the write's
    # own 403. Rows that run no gate say `gate: false`.
    def withheld?
      options[:gate] != false && MatrixWorld::WITHHELD.fetch(state).include?(gate_subject) && !operator?
    end

    # A service that refuses a tombstoned node, parent or target answers 422 to
    # a caller who got past every gate.
    def refused? = Array(options[:refuses]).any? { |subject| tombstoned?(subject) }

    def expected
      return 503 if state == :maintenance
      return 403 if tier == :read_only || !allowed?
      return 410 if withheld?
      return 422 if refused?

      options.fetch(:ok, 200)
    end
  end

  MODS = Rails.root.join('spec/fixtures/files/work-mods.xml')
  DWC  = Rails.root.join('spec/fixtures/files/dwc.xml')

  def self.upload(path, type) = Rack::Test::UploadedFile.new(path, type)

  # 'controller#action' => [policy, options], with an `@variant` suffix when a
  # route needs a second row. `on:` names the subject the :id resolves to, which
  # is also the subject the policy and the tombstone gate read.
  # `params:` builds the body from the world, `path:` the other path segments.
  # `fresh:` gives the row a throwaway subject, because a success damages it.
  # `refuses:` names the subjects whose own tombstone a service refuses with 422.
  MATRIX = {
    'resources#put_mods'                  => [:edit, { on: :work, params: ->(_) { { binary: upload(MODS, 'application/xml') } } }],
    'resources#update_permissions'        => [:edit, { on: :work, json: true,
                                                         params: ->(w) { { permissions: { read: Resource.find(w.work.noid).read_groups } } } }],
    'resources#update_thumbnails'         => [:edit, { on: :work, params: ->(_) { { thumbnail: 'https://iiif.example/matrix.jpg' } } }],
    'resources#update_parent'             => [:operator, { on: :work, fresh: true, refuses: %i[work empty_collection],
                                                             params: ->(w) { { parent_id: w.empty_collection.noid } } }],
    'resources#tombstone'                 => [:edit, { on: :work, fresh: true }],
    'resources#tombstone@file_set'        => [:operator, { on: :file_set, fresh: true }],
    'resources#restore'                   => [:operator, { on: :work, gate: false, fresh: true }],
    'resources#restore@file_set'          => [:operator, { on: :file_set, gate: false, fresh: true, refuses: %i[work] }],
    'resources#destroy'                   => [:admin, { on: :empty_collection, gate: false, fresh: true, ok: 204 }],
    'resources#reindex'                   => [:reindex, { on: :work, gate: false, ok: 204 }],
    'resources#reindex_subtree'           => [:reindex, { on: :empty_collection, gate: false }],
    'darwin_core#update'                  => [:edit, { on: :work, params: ->(_) { { binary: upload(DWC, 'application/xml') } } }],
    'darwin_core#destroy'                 => [:edit, { on: :work, fresh: true, ok: 204 }],
    'works#update_image_derivatives'      => [:edit, { on: :work, params: ->(_) { { small: 'https://iiif.example/small.jpg' } } }],
    'works#update_derivative_permissions' => [:edit, { on: :work, json: true, params: ->(_) { {} } }],
    'works#update_full_text'              => [:edit, { on: :work, params: ->(_) { { text: 'matrix' } } }],
    'works#complete'                      => [:edit, { on: :work }],
    'works#mark_incomplete'               => [:edit, { on: :work, params: ->(_) { { reason: 'matrix' } } }],
    'works#clear_incomplete'              => [:edit, { on: :work }],
    'works#add_linked_member'             => [:link_member, { on: :work, refuses: %i[work empty_collection],
                                                                params: ->(w) { { collection_id: w.empty_collection.noid } } }],
    # The one grant :system holds here: a featured target, acting as the
    # Work's depositor.
    'works#add_linked_member@system'      => [:link_member, { on: :work, system_scoped: true, refuses: %i[work],
                                                                params: ->(w) { { collection_id: w.featured_collection.noid } } }],
    'works#remove_linked_member'          => [:link_member, { on: :work, path: ->(w) { { collection_id: w.empty_collection.noid } } }],
    'works#remove_linked_member@system'   => [:link_member, { on: :work, system_scoped: true,
                                                                path: ->(w) { { collection_id: w.featured_collection.noid } } }],
    'works#add_association'               => [:operator, { on: :work, refuses: %i[work],
                                                             params: ->(w) { { work_id: w.other_work.noid, type: 'is_figure_for' } } }],
    'works#remove_association'            => [:operator, { on:   :work,
                                                           path: ->(w) { { type: 'is_figure_for', work_id: w.other_work.noid } } }],
    # No test tier but the admin edits the Collection, and :system may never
    # create a Work.
    'works#create'                        => [:admin, { on: :collection, gate: false, params: ->(w) { { collection_id: w.collection.noid } } }],
    'collections#create'                  => [:create_container, { on: :sub_community, gate: false, refuses: %i[sub_community],
                                                                     params: ->(w) { { parent_id: w.sub_community.noid } } }],
    'communities#create'                  => [:create_container, { on: :sub_community, gate: false, refuses: %i[sub_community],
                                                                     params: ->(w) { { parent_id: w.sub_community.noid } } }],
    'collections#update_featured'         => [:edit, { on: :empty_collection, json: true, params: ->(_) { { featured: false } } }],
    'file_sets#create'                    => [:edit, { on: :work, json: true, params: ->(w) { { work_id: w.work.noid, classification: 'generic' } } }],
    'file_sets#update'                    => [:edit, { on:     :file_set,
                                                       params: ->(_) { { binary: upload(MatrixWorld::FIXTURE, 'application/octet-stream') } } }],
    'file_sets#update_iiif_service'       => [:edit, { on: :file_set, params: ->(_) { { uri: 'https://iiif.example/service' } } }],
    'file_sets#destroy'                   => [:admin, { on: :file_set, gate: false, fresh: true, ok: 204 }],
    'blobs#create'                        => [:edit, { on: :work, params: lambda { |w|
      { work_id: w.work.noid, binary: upload(MatrixWorld::FIXTURE, 'application/octet-stream') }
    } }],
    'blobs#update'                        => [:edit, { on: :blob, params: ->(_) { { binary: upload(MatrixWorld::FIXTURE, 'application/octet-stream') } } }],
    'blobs#rollback'                      => [:edit, { on: :blob, json: true,
                                                         params: ->(w) { { version_id: Blob.find(w.blob.noid).file_identifiers.first.to_s[%r{/(v\d+)/}, 1] } } }],
    'blobs#destroy'                       => [:admin, { on: :blob, gate: false, fresh: true, ok: 204 }]
  }.freeze

  # Writes keyed on something other than a resource in this tree. Each names
  # where its gate is covered instead.
  UNSCOPED = {
    'compilations#create'                     => 'a Set, not a resource: spec/requests/compilations_spec.rb',
    'compilations#update'                     => 'a Set, not a resource: spec/requests/compilations_spec.rb',
    'compilations#destroy'                    => 'a Set, not a resource: spec/requests/compilations_spec.rb',
    'compilations#add_included_collection'    => 'a Set, not a resource: spec/requests/compilations_spec.rb',
    'compilations#remove_included_collection' => 'a Set, not a resource: spec/requests/compilations_spec.rb',
    'compilations#add_included_work'          => 'a Set, not a resource: spec/requests/compilations_spec.rb',
    'compilations#remove_included_work'       => 'a Set, not a resource: spec/requests/compilations_spec.rb',
    'compilations#add_exclusion'              => 'a Set, not a resource: spec/requests/compilations_spec.rb',
    'compilations#remove_exclusion'           => 'a Set, not a resource: spec/requests/compilations_spec.rb',
    'compilations#publish'                    => 'a Set, not a resource: spec/requests/compilations_spec.rb',
    'compilations#unpublish'                  => 'a Set, not a resource: spec/requests/compilations_spec.rb',
    'people#create'                           => 'a Person, not a resource: spec/requests/people_spec.rb',
    'people#update'                           => 'a Person, not a resource: spec/requests/people_spec.rb',
    'people#add_affiliation'                  => 'a Person, not a resource: spec/requests/people_spec.rb',
    'people#remove_affiliation'               => 'a Person, not a resource: spec/requests/people_spec.rb',
    'users#update'                            => 'accounts: spec/requests/users_spec.rb',
    'users#update_by_email'                   => 'accounts: spec/requests/users_spec.rb',
    'users#preferred_account'                 => 'accounts: spec/requests/user_accounts_spec.rb',
    'users/tokens#nuid'                       => 'token minting: spec/requests/users_spec.rb',
    'users/tokens#revoke'                     => 'token revocation: spec/requests/users_spec.rb',
    'embargoes#release'                       => 'a :system sweep: spec/requests/embargoes_spec.rb',
    'fixity_checks#create'                    => 'the fixity checker only: spec/requests/fixity_checks_spec.rb',
    'audit_events#create'                     => 'the operator ledger: spec/requests/audit_events_spec.rb',
    'maintenance#update'                      => 'the maintenance window: spec/requests/maintenance_read_only_spec.rb',
    'resources#preview'                       => 'renders posted MODS and writes nothing',
    'resources#find_many'                     => 'a POST that reads: a row in the read matrix',
    'oai#index'                               => 'the OAI-PMH POST form of the harvest read: spec/requests/oai_spec.rb',
    'blobs#find_many_versions'                => 'a POST that reads: spec/requests/binary_versions_spec.rb',
    'devise/passwords#create'                 => 'a devise default route; Atlas takes no password',
    'devise/passwords#update'                 => 'a devise default route; Atlas takes no password'
  }.freeze

  def self.key_of(row) = row.split('@').first
end
# rubocop:enable Metrics/ModuleLength

# default_auth: false — the global admin default would be served everything.
RSpec.describe 'Write matrix', type: :request, default_auth: false do
  include_context 'access matrix callers'

  attr_reader :world

  after { Atlas.persister.wipe! }

  # One drawn route per row. A PUT twin of a PATCH answers the same gate, so
  # the PATCH is the one probed.
  def route_for(row)
    key = WriteMatrix.key_of(row)
    routes = MatrixWorld.routes.select { |route, k| k == key && route.verb != 'GET' }.map(&:first)
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
    @world = MatrixWorld.new(editor_nuid: users[:editor].nuid).build!
    # Built now, so the first cell that names them does not count their
    # creation as a write it made.
    [world.other_work, world.featured_collection]
    world.apply!(state) unless state == :maintenance
  end

  def subject_for(options) = (options[:fresh] && @scratch) || world.public_send(options[:on])

  def check(state, row, tier)
    policy, options = WriteMatrix::MATRIX.fetch(row)
    expected = WriteMatrix::Cell.new(state, tier, policy, options).expected
    before = fingerprint unless expected.between?(200, 299)
    request!(row, tier)
    fault = ', and changed the repository' if before && fingerprint != before
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

  describe 'the route inventory' do
    it 'gives every write route a row or a reason' do
      writes = MatrixWorld.routes.reject { |route, _| route.verb == 'GET' }.map(&:last).uniq
      rows = WriteMatrix::MATRIX.keys.map { |row| WriteMatrix.key_of(row) }
      unclassified = writes - rows - WriteMatrix::UNSCOPED.keys
      expect(unclassified).to be_empty,
                              "Add a row to MATRIX, or a reason to UNSCOPED, for: #{unclassified.join(', ')}"
    end

    it 'names no route that the application no longer draws' do
      drawn = MatrixWorld.routes.map(&:last)
      rows = WriteMatrix::MATRIX.keys.map { |row| WriteMatrix.key_of(row) }
      expect(rows + WriteMatrix::UNSCOPED.keys - drawn).to be_empty
    end
  end
end
