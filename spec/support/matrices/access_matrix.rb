# frozen_string_literal: true

require_relative 'tree'

# The read matrix's table: what every read route answers, for each state a
# resource can be in and each caller tier. A route is a row, and its policy says
# what each cell should get. It loads without RSpec, so bin/acl-coverage can read
# it; spec/requests/access_matrix_spec.rb sends the requests. See
# docs/testing.md.
#
# rubocop:disable Metrics/ModuleLength -- the rows are one table, and splitting
# it would scatter a single decision across modules.
module AccessMatrix
  # The states that withhold a Work's file bytes but not its record: metadata
  # stays public under an embargo and under a tier reservation.
  BYTES_WITHHELD = %i[embargoed tier_gated].freeze

  STATES    = (MatrixTree::STATES + BYTES_WITHHELD).freeze
  TIERS     = %i[guest standard editor delegate admin].freeze
  OPERATORS = MatrixTree::OPERATORS
  WITHHELD  = MatrixTree::WITHHELD.merge(BYTES_WITHHELD.index_with { [] }).freeze
  PRIVATE_SUBJECTS = MatrixTree::PRIVATE_SUBJECTS
  MARKERS = MatrixTree::MARKERS

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
end
# rubocop:enable Metrics/ModuleLength
