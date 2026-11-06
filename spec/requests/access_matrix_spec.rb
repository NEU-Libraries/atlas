# frozen_string_literal: true

require 'rails_helper'

# What every read route answers, for each state a Work can be in and each
# caller tier. A route is a row, and its policy says what each cell should get.
# The inventory examples fail when a route has no row, so a new route cannot
# ship without someone deciding what a tombstone or a private ACL means for it.
# See docs/testing.md.
module AccessMatrix
  STATES    = %i[live private work_tombstoned file_set_tombstoned].freeze
  TIERS     = %i[guest standard editor delegate admin].freeze
  OPERATORS = %i[delegate admin].freeze

  # The editor holds an edit grant on the Work, which is what lets it past a
  # private ACL. A tombstone leaves the ACL public.
  Cell = Struct.new(:state, :tier) do
    def readable? = state != :private || %i[editor admin].include?(tier)
    def operator? = OPERATORS.include?(tier)
    def work_tombstoned? = state == :work_tombstoned
    def tombstoned? = %i[work_tombstoned file_set_tombstoned].include?(state)

    # The per-resource read gate answers first, so a caller who may not read
    # the resource learns nothing about its tombstone.
    def gated = readable? ? yield : 403
  end

  POLICIES = {
    read:          ->(c) { c.gated { 200 } },
    redirect:      ->(c) { c.gated { 302 } },
    # The record of a tombstoned resource still renders, as 410, for the page
    # that explains the removal.
    work_record:   ->(c) { c.gated { c.work_tombstoned? ? 410 : 200 } },
    leaf_record:   ->(c) { c.gated { c.tombstoned? ? 410 : 200 } },
    # The bytes, and the Work's file lists, are withheld below the operator tiers.
    bytes:         ->(c) { c.gated { c.tombstoned? && !c.operator? ? 410 : 200 } },
    file_list:     ->(c) { c.gated { c.work_tombstoned? && !c.operator? ? 410 : 200 } },
    # A class-wide operator verb makes no per-resource read decision.
    operator:      ->(c) { c.operator? ? 200 : 403 },
    operator_read: ->(c) { c.operator? ? c.gated { 200 } : 403 },
    admin:         ->(c) { c.tier == :admin ? 200 : 403 },
    # A container above the Work: the Work's state does not reach it.
    container:     ->(_) { 200 }
  }.freeze

  # 'controller#action' => [policy, options]. `on:` names the subject the :id
  # resolves to when the path's first segment does not.
  MATRIX = {
    'works#show'                 => [:work_record],
    'works#mods'                 => [:read],
    'works#mets'                 => [:read],
    'works#associations'         => [:read],
    'works#linked_members'       => [:read],
    'works#assets'               => [:file_list],
    'works#file_sets'            => [:file_list],
    'works#file_revisions'       => [:file_list],
    'works#tombstoned_assets'    => [:operator],
    'works#health_check'         => [:operator],
    'works#index'                => [:admin],
    'darwin_core#show'           => [:read],
    'darwin_core#versions'       => [:operator],
    'darwin_core#version'        => [:read],
    'file_sets#show'             => [:leaf_record],
    'file_sets#mets'             => [:read],
    'file_sets#index'            => [:admin],
    'blobs#show'                 => [:leaf_record],
    'blobs#content'              => [:bytes],
    'blobs#version_content'      => [:bytes],
    'blobs#ancestry'             => [:read],
    'blobs#versions'             => [:operator],
    'blobs#index'                => [:admin],
    'delegates#show'             => [:work_record],
    'resources#show'             => [:redirect],
    'resources#mods'             => [:read],
    'resources#mods_versions'    => [:operator],
    'resources#mods_version'     => [:read],
    'resources#permissions'      => [:read],
    'resources#descendant_works' => [:container, { on: :collection }],
    'resource_children#show'     => [:operator, { on: :collection }],
    'audit_events#index'         => [:operator_read],
    'index_documents#show'       => [:operator_read],
    'search_explanations#show'   => [:operator_read, { query: { q: 'title' } }],
    'collections#show'           => [:container],
    'collections#mods'           => [:container],
    'collections#children'       => [:container],
    'communities#show'           => [:container],
    'communities#mods'           => [:container],
    'communities#children'       => [:container]
  }.freeze

  # Reads keyed on something other than a Work, its leaves or its containers.
  # Each names where its gate is covered instead.
  UNSCOPED = {
    'compilations#index'       => 'a Set, not a Work: spec/requests/compilations_spec.rb',
    'compilations#show'        => 'a Set, not a Work: spec/requests/compilations_spec.rb',
    'compilations#contents'    => 'a Set, not a Work: spec/requests/compilations_spec.rb',
    'communities#index'        => 'a roll of containers: spec/requests/index_read_gate_spec.rb',
    'collections#index'        => 'a roll of containers: spec/requests/index_read_gate_spec.rb',
    'people#index'             => 'a Person, not a Work: spec/requests/people_spec.rb',
    'people#show'              => 'a Person, not a Work: spec/requests/people_spec.rb',
    'search#index'             => 'a query, gated per document: spec/requests/search_spec.rb',
    'resources#find_many'      => 'a batch, filtered per resource: spec/requests/resources_spec.rb',
    'resources#preview'        => 'renders posted MODS and reads no resource',
    'blobs#find_many_versions' => 'class-wide :read_versions: spec/requests/binary_versions_spec.rb',
    'fixity_checks#due'        => 'the fixity checker only: spec/requests/fixity_checks_spec.rb',
    'oai#index'                => 'the public metadata harvest: spec/requests/oai_spec.rb',
    'docs#show'                => 'the API documentation',
    'maintenance#show'         => 'the maintenance flag',
    'maintenance#reset'        => 'the development data reset',
    'health#show'              => 'service health',
    'metrics#latency'          => 'operator latency figures: spec/requests/metrics_spec.rb',
    'users/tokens#show'        => "the caller's own account",
    'users#index'              => 'accounts: spec/requests/users_spec.rb',
    'users#show'               => 'accounts: spec/requests/users_spec.rb',
    'users#accounts'           => 'accounts: spec/requests/user_accounts_spec.rb',
    'devise/passwords#new'     => 'a devise default route; Atlas takes no password',
    'devise/passwords#edit'    => 'a devise default route; Atlas takes no password'
  }.freeze

  # Every route the application draws, framework routes aside, as
  # [route, 'controller#action'].
  def self.routes
    Rails.application.routes.routes.filter_map do |route|
      controller = route.defaults[:controller]
      next if controller.nil? || controller.start_with?('rails/', 'active_storage/', 'action_mailbox/')

      [route, "#{controller}##{route.defaults[:action]}"]
    end
  end
end

# default_auth: false — the global admin default is an operator and would be
# served everything.
RSpec.describe 'Access matrix', type: :request, default_auth: false do
  let!(:guest) do
    User.find_by(role: :guest) ||
      User.create!(email: 'guest-matrix@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000001', name: 'User, Guest', role: :guest)
  end
  let!(:admin) { ensure_default_admin! }
  let(:users) do
    {
      guest:    guest,
      standard: User.create!(email: 'standard-matrix@example.invalid', password: SecureRandom.hex(16),
                             nuid: '000000063', name: 'Doe, Standard', role: :standard, groups: []),
      editor:   User.create!(email: 'editor-matrix@example.invalid', password: SecureRandom.hex(16),
                             nuid: '000000061', name: 'Roe, Editor', role: :standard, groups: []),
      delegate: User.create!(email: 'delegate-matrix@example.invalid', password: SecureRandom.hex(16),
                             nuid: '000000062', name: 'Williams, Delegate', role: :privileged,
                             groups: [Permissions::ADMIN_GROUP]),
      admin:    admin
    }
  end

  let(:fixture)    { Rails.root.join('spec/fixtures/files/example.bin') }
  let(:bytes)      { File.binread(fixture) }
  let(:community)  { public_community! }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work) do
    work = WorkCreator.call(parent_id: collection.noid)
    work.publicize
    work.edit_users = [users[:editor].nuid]
    Atlas.persister.save(resource: work)
  end
  let(:blob)     { BlobCreator.call(work_id: work.noid, original_filename: 'a.bin', path: fixture.to_s) }
  let(:file_set) { blob.parent }
  let(:delegate) do
    DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name, uri: 'https://iiif.example/t.jpg')
  end

  after { Atlas.persister.wipe! }

  def headers_for(tier)
    signed_auth_headers(tier == :guest ? nil : users[tier].nuid)
  end

  # Every route in the matrix must have something to serve, or a 404 would
  # pass for a refusal. The METS and Darwin Core records give their routes one.
  def build_world!
    [blob, delegate]
    WorkMETSRebuilder.call(work: work)
    dwc = Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/dwc.xml'), 'application/xml')
    put "/resources/#{work.noid}/dwc", headers: headers_for(:admin), params: { binary: dwc }
    expect(response).to have_http_status(:ok)
  end

  def apply!(state)
    resource = { private: work, work_tombstoned: work, file_set_tombstoned: file_set }[state]
    return if resource.nil?

    resource = Resource.find(resource.noid)
    state == :private ? resource.privatize : resource.tombstone(by: admin.nuid)
    Atlas.persister.save(resource: resource)
  end

  def subject_ids
    { 'works' => work.noid, 'file_sets' => file_set.noid, 'files' => blob.noid,
      'delegates' => delegate.noid, 'resources' => work.noid,
      'collections' => collection.noid, 'communities' => community.noid }
  end

  # A pinned version is looked up, as an operator, through the listing beside
  # it, before the state is applied.
  def path_for(route, options)
    path = route.path.spec.to_s.sub('(.:format)', '')
    id = options[:on] ? public_send(options[:on]).noid : subject_ids[path.split('/')[1]]
    path = path.sub(':id', id.to_s)
    return path unless path.include?(':version_id')

    get path.sub(%r{/:version_id.*}, ''), headers: headers_for(:admin)
    path.sub(':version_id', response.parsed_body['versions'].first['version_id'].to_s)
  end

  # A refusal must carry no bytes, and a served byte route must carry them all.
  def bytes_wrong?(policy)
    served = response.body.b
    response.status == 200 && policy == :bytes ? served != bytes : response.status != 200 && served.include?(bytes)
  end

  def misses_for(state, paths)
    paths.flat_map do |key, path|
      policy, options = AccessMatrix::MATRIX[key]
      AccessMatrix::TIERS.filter_map do |tier|
        get path, params: options&.dig(:query), headers: headers_for(tier)
        expected = AccessMatrix::POLICIES.fetch(policy).call(AccessMatrix::Cell.new(state, tier))
        next if response.status == expected && !bytes_wrong?(policy)

        "#{key} as #{tier}: expected #{expected}, got #{response.status}#{', bytes wrong' if bytes_wrong?(policy)}"
      end
    end
  end

  AccessMatrix::STATES.each do |state|
    it "answers every route as its row says when the Work is #{state.to_s.tr('_', ' ')}" do
      build_world!
      paths = AccessMatrix.routes.filter_map do |route, key|
        next unless route.verb == 'GET' && AccessMatrix::MATRIX.key?(key)

        [key, path_for(route, AccessMatrix::MATRIX[key][1] || {})]
      end
      apply!(state)

      misses = misses_for(state, paths)
      expect(misses).to be_empty, "#{misses.size} cells differ:\n  #{misses.join("\n  ")}"
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
