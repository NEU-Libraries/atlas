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

  # Beyond the shared states: a Work only one group may read, a purged
  # Collection, and a Blob no FileSet holds.
  STATES    = (MatrixTree::STATES + BYTES_WITHHELD + %i[group_read purged unattached]).freeze
  TIERS     = %i[guest standard loader privileged group_reader curator editor group_editor owner jwt_editor staff
                 delegate obo_refused fixity acting_admin admin].freeze
  OPERATORS = MatrixTree::OPERATORS
  WITHHELD  = MatrixTree::WITHHELD.merge((STATES - MatrixTree::STATES).index_with { [] }).freeze
  PRIVATE_SUBJECTS = MatrixTree::PRIVATE_SUBJECTS
  MARKERS = MatrixTree::MARKERS
  RESERVED_GROUP = MatrixTree::RESERVED_GROUP

  # Subjects whose URL a state withholds while the record stays readable: an
  # embargo keeps the gated full-resolution URL from everyone outside
  # MatrixTree::URI_AUDIENCE. The marker check holds it on every route.
  URI_WITHHELD = { embargoed: %i[gated_delegate] }.freeze

  # The axis values these tiers and states exercise: see ACLAxes.
  AXES = %i[cred_guest cred_assertion cred_obo cred_jwt cred_fixity grant_public grant_read_group grant_edit_users
            grant_edit_groups grant_depositor role_guest role_standard role_loader role_privileged role_delegate
            role_staff role_admin state_live state_private state_work_tomb state_file_set_tomb
            state_collection_tomb state_community_tomb state_embargoed state_tier_reserved state_purged
            state_unattached].freeze

  # Every expected cell comes from what the tier holds (MatrixTree) and what
  # the state does to the subject. A tombstone leaves the ACL public.
  Cell = Struct.new(:state, :tier, :subject, :options) do
    def readable?
      return MatrixTree::ADMINS.include?(tier) if state == :unattached && subject == :blob
      return true unless %i[private group_read].include?(state) && PRIVATE_SUBJECTS.include?(subject)

      MatrixTree.work_reader?(tier) || (state == :group_read && tier == :group_reader)
    end

    def operator? = OPERATORS.include?(tier)
    def admin? = MatrixTree::ADMINS.include?(tier)
    def tombstoned? = WITHHELD.fetch(state).include?(subject)
    def withheld? = tombstoned? && !operator?

    def bytes_withheld?
      return false unless subject == :blob

      case state
      when :embargoed  then MatrixTree::EMBARGO_BYPASS.exclude?(tier)
      when :tier_gated then MatrixTree::TIER_AUDIENCE.exclude?(tier)
      else false
      end
    end

    def bytes_status
      return 410 if withheld?

      bytes_withheld? ? 403 : 200
    end

    # The per-resource read gate answers first, so a caller who may not read
    # the resource learns nothing about its tombstone. A purged id resolves to
    # nothing, so the class check passes and the route answers as removed.
    def gated
      return (options || {}).fetch(:purged, 404) if state == :purged && subject == :empty_collection

      readable? ? yield : 403
    end
  end

  # The cell's status: a refused caller is turned away before any policy runs.
  def self.expected(state, tier, subject, policy, options = {})
    return 403 if MatrixTree::REFUSED.include?(tier)

    POLICIES.fetch(policy).call(Cell.new(state, tier, subject, options))
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
    admin:         ->(c) { c.admin? ? 200 : 403 },
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
    'works#citation'             => [:withheld],
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
    # The large image: a gated, full-resolution copy.
    'delegates#show@gated'       => [:record, { on: :gated_delegate }],
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
    'collections#show'           => [:record, { on: :empty_collection, purged: 410 }],
    'collections#mods'           => [:withheld, { on: :empty_collection }],
    'collections#children'       => [:record, { on: :empty_collection }],
    'communities#show'           => [:record, { on: :sub_community }],
    'communities#mods'           => [:withheld, { on: :sub_community }],
    'communities#children'       => [:record, { on: :sub_community }]
  }.freeze

  # Every route the matrices reach has a row in one of them. A route none can
  # cross with its callers goes here with a reason naming where it is tested.
  UNSCOPED = {}.freeze

  # The subject a path's first segment names, absent an `on:`.
  SEGMENT_SUBJECTS = {
    'works' => :work, 'file_sets' => :file_set, 'files' => :blob, 'delegates' => :delegate,
    'resources' => :work, 'collections' => :empty_collection, 'communities' => :sub_community
  }.freeze
end
# rubocop:enable Metrics/ModuleLength
