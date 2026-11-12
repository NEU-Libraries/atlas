# frozen_string_literal: true

require_relative 'tree'

# The write matrix's table: what every write route answers, for each state a
# resource can be in and each caller tier, on the read matrix's world. It
# loads without RSpec, so bin/acl-coverage can read it;
# spec/support/write_matrix_runner.rb sends the requests. See docs/testing.md.
#
# it would scatter a single decision across modules.
module WriteMatrix
  # Least to most privileged, so most rows refuse until their last cells.
  # :system sits beside the human ladder, so it goes after the delegate.
  TIERS  = %i[guest read_only obo_refused fixity standard loader privileged group_reader curator editor
              group_editor owner jwt_editor staff delegate system acting_admin admin].freeze
  # A private Work changes no write cell: its editors hold the grant either
  # way and nobody else could write. So it runs its refusals alone, below.
  STATES = (MatrixTree::STATES - %i[private] + %i[maintenance]).freeze

  # The axis values these tiers and states exercise: see ACLAxes.
  AXES = %i[cred_guest cred_assertion cred_obo cred_jwt cred_jwt_read_only cred_system cred_fixity grant_public
            grant_edit_users grant_edit_groups grant_depositor grant_container role_guest role_standard role_loader
            role_privileged role_delegate role_staff role_system role_admin state_live state_private
            state_work_tomb state_file_set_tomb state_collection_tomb state_community_tomb
            state_maintenance].freeze

  # The subjects a grant on the Work reaches; a grant on a container reaches
  # the rest.
  EDITOR_SUBJECTS = %i[work file_set blob].freeze

  # The tiers each policy admits, before the floors and the tombstone gate.
  POLICIES = {
    edit:             ->(c) { c.admin? || c.editor_of_subject? },
    operator:         ->(c) { c.operator? },
    admin:            ->(c) { c.admin? },
    reindex:          ->(c) { c.admin? || c.tier == :system },
    # A Work needs an edit grant on its Collection; :system may never create one.
    create_work:      ->(c) { c.admin? || MatrixTree::CONTAINER_EDITORS.include?(c.tier) },
    supply_handle:    ->(c) { c.operator? && (c.admin? || MatrixTree::CONTAINER_EDITORS.include?(c.tier)) },
    create_container: ->(c) { c.admin? || c.tier == :system || MatrixTree::CONTAINER_EDITORS.include?(c.tier) },
    link_member:      ->(c) { c.admin? || (c.tier == :system && c.options[:system_scoped]) }
  }.freeze

  Cell = Struct.new(:state, :tier, :policy, :options) do
    def gate_subject = options.fetch(:on)
    def allowed? = POLICIES.fetch(policy).call(self)
    def admin? = MatrixTree::ADMINS.include?(tier)
    def operator? = MatrixTree::OPERATORS.include?(tier)
    def tombstoned?(subject) = MatrixTree::TOMBSTONED[state] == subject

    def editor_of_subject?
      editors = EDITOR_SUBJECTS.include?(gate_subject) ? MatrixTree::WORK_EDITORS : MatrixTree::CONTAINER_EDITORS
      editors.include?(tier)
    end

    # A tombstone refuses a write below the operator tiers, after the write's
    # own 403. Rows that run no gate say `gate: false`.
    def withheld?
      options[:gate] != false && MatrixTree::WITHHELD.fetch(state).include?(gate_subject) && !operator?
    end

    # A service that refuses a tombstoned node, parent or target answers 422 to
    # a caller who got past every gate.
    def refused? = Array(options[:refuses]).any? { |subject| tombstoned?(subject) }

    # The acting-as refusal comes before authorization, so even the
    # maintenance window answers it with 403.
    def expected
      return 403 if tier == :obo_refused
      return 503 if state == :maintenance
      return 403 if %i[read_only fixity].include?(tier) || !allowed?
      return 410 if withheld?
      return 422 if refused?

      options.fetch(:ok, 200)
    end
  end

  # Resolved at request time, so the table loads without a booted app.
  def self.fixture(name) = Rails.root.join('spec/fixtures/files', name)
  def self.upload(name, type) = Rack::Test::UploadedFile.new(fixture(name), type)

  # 'controller#action' => [policy, options], with an `@variant` suffix when a
  # route needs a second row. `on:` names the subject the :id resolves to, which
  # is also the subject the policy and the tombstone gate read.
  # `params:` builds the body from the world, `path:` the other path segments.
  # `fresh:` gives the row a throwaway subject, because a success damages it.
  # `refuses:` names the subjects whose own tombstone a service refuses with 422.
  MATRIX = {
    'resources#put_mods'                  => [:edit, { on: :work, params: ->(_) { { binary: upload('work-mods.xml', 'application/xml') } } }],
    # This row and the tier-policy row change a value the envelope carries, so
    # the envelope check can see whether the write rewrote it.
    'resources#update_permissions'        => [:edit, { on: :work, json: true, params: lambda { |w|
      { permissions: { read: (Resource.find(w.work.noid).read_groups + [MatrixTree::READER_GROUP]).uniq } }
    } }],
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
    'darwin_core#update'                  => [:edit, { on: :work, params: ->(_) { { binary: upload('dwc.xml', 'application/xml') } } }],
    'darwin_core#destroy'                 => [:edit, { on: :work, fresh: true, ok: 204 }],
    'works#update_image_derivatives'      => [:edit, { on: :work, params: ->(_) { { small: 'https://iiif.example/small.jpg' } } }],
    'works#update_derivative_permissions' => [:edit, { on: :work, json: true, params: ->(_) { { service: [MatrixTree::EDITOR_GROUP] } } }],
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
    'works#create'                        => [:create_work, { on: :collection, gate: false, params: ->(w) { { collection_id: w.collection.noid } } }],
    'works#create@handle'                 => [:supply_handle, { on: :collection, gate: false, params: ->(w) { { collection_id: w.collection.noid, handle: "2047/m-#{SecureRandom.hex(4)}" } } }], # unique per cell, or a success makes the next one 409
    'collections#create'                  => [:create_container, { on: :sub_community, gate: false, refuses: %i[sub_community],
                                                                     params: ->(w) { { parent_id: w.sub_community.noid } } }],
    'communities#create'                  => [:create_container, { on: :sub_community, gate: false, refuses: %i[sub_community],
                                                                     params: ->(w) { { parent_id: w.sub_community.noid } } }],
    'collections#update_featured'         => [:edit, { on: :empty_collection, json: true, params: ->(_) { { featured: false } } }],
    'file_sets#create'                    => [:edit, { on: :work, json: true, params: ->(w) { { work_id: w.work.noid, classification: 'generic' } } }],
    'file_sets#update'                    => [:edit, { on:     :file_set,
                                                       params: ->(_) { { binary: upload('example.bin', 'application/octet-stream') } } }],
    'file_sets#update_iiif_service'       => [:edit, { on: :file_set, params: ->(_) { { uri: 'https://iiif.example/service' } } }],
    'file_sets#destroy'                   => [:admin, { on: :file_set, gate: false, fresh: true, ok: 204 }],
    'blobs#create'                        => [:edit, { on: :work, params: lambda { |w|
      { work_id: w.work.noid, binary: upload('example.bin', 'application/octet-stream') }
    } }],
    'blobs#update'                        => [:edit, { on: :blob, params: ->(_) { { binary: upload('example.bin', 'application/octet-stream') } } }],
    'blobs#rollback'                      => [:edit, { on: :blob, json: true,
                                                         params: ->(w) { { version_id: Blob.find(w.blob.noid).file_identifiers.first.to_s[%r{/(v\d+)/}, 1] } } }],
    'blobs#destroy'                       => [:admin, { on: :blob, gate: false, fresh: true, ok: 204 }]
  }.freeze

  # Every route the matrices reach has a row in one of them. A route none can
  # cross with its callers goes here with a reason naming where it is tested.
  UNSCOPED = {}.freeze

  def self.key_of(row) = row.split('@').first
end
