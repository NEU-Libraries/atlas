# frozen_string_literal: true

# The support files load alphabetically, and this one sorts first.
require_relative 'mods_fixture_helper'
require_relative 'matrices/tree'

# The fixture tree, the states and the callers that both access matrices run
# against, so the read matrix and the write matrix describe the same world. See
# docs/testing.md.
class AccessMatrixFixtures
  include MODSFixtureHelper
  include MatrixTree

  # The callers whose credential is not a plain signed assertion.
  CREDENTIALS = {
    guest:        ->(_) { {} },
    system:       ->(ctx) { ctx.token_headers(:system_token, ctx.system_user) },
    fixity:       ->(ctx) { ctx.token_headers(:fixity_token, ctx.fixity_user) },
    read_only:    ->(ctx) { ctx.jwt_headers(ctx.admin, read_only: true) },
    jwt_editor:   ->(ctx) { ctx.jwt_headers(ctx.users[:editor]) },
    obo_refused:  ->(ctx) { ctx.assertion_headers(ctx.users[:standard], obo: ctx.users[:editor]) },
    acting_admin: ->(ctx) { ctx.assertion_headers(ctx.admin, obo: ctx.users[:owner]) }
  }.freeze

  FIXTURE = Rails.root.join('spec/fixtures/files/example.bin')
  DWC     = Rails.root.join('spec/fixtures/files/dwc.xml')

  attr_reader :community, :collection, :work, :blob, :file_set, :delegate, :gated_delegate, :empty_collection,
              :sub_community

  # Every route the application draws, framework routes aside, as
  # [route, 'controller#action'].
  def self.routes
    Rails.application.routes.routes.filter_map do |route|
      controller = route.defaults[:controller]
      next if controller.nil? || controller.start_with?('rails/', 'active_storage/', 'action_mailbox/')

      [route, "#{controller}##{route.defaults[:action]}"]
    end
  end

  # Every route in a matrix must have something to answer, or a 404 would pass
  # for a refusal. The METS and Darwin Core records give their routes one.
  def build!
    @community  = public_community!
    @collection = CollectionCreator.call(parent_id: community.noid)
    build_work!
    build_leaves!
    build_containers!
    [collection, empty_collection, sub_community].each { |container| curate!(container) }
    WorkMETSRebuilder.call(work: work)
    Work.find(work.noid).darwin_core_xml = File.read(DWC)
    self
  end

  def apply!(state)
    return send(:"#{state}!") if %i[group_read purged unattached].include?(state)

    resource = { private: work, work_tombstoned: work, file_set_tombstoned: file_set,
                 collection_tombstoned: empty_collection, community_tombstoned: sub_community }[state]
    return if resource.nil?

    resource = Resource.find(resource.noid)
    state == :private ? resource.privatize : resource.tombstone(by: DefaultAuthHeaders::ADMIN_NUID)
    Atlas.persister.save(resource: resource)
  end

  # A second Work, for the association routes, which need a Work at each end.
  def other_work
    @other_work ||= public_work!
  end

  # A featured Collection, for the one :link_member grant :system holds.
  def featured_collection
    @featured_collection ||= CollectionCreator.call(parent_id: community.noid, featured: true)
  end

  # A throwaway copy of a subject, in the shape the state gives the shared one,
  # for a write that would damage the shared one. A leaf hangs off the shared
  # Work, so a tombstone on that Work withholds it too.
  def scratch(subject, state)
    resource = case subject
               when :work             then public_work! { |w| grant_work!(w) }.tap { |w| scratch_dwc!(w) }
               when :file_set         then FileSetCreator.call(work_id: work.noid, classification: Classification.generic)
               when :blob             then BlobCreator.call(work_id: work.noid, original_filename: 'scratch.bin',
                                                            path: FIXTURE.to_s)
               when :empty_collection then curate!(CollectionCreator.call(parent_id: community.noid))
               end
    return resource unless TOMBSTONED[state] == subject

    resource.tombstone(by: DefaultAuthHeaders::ADMIN_NUID)
    Atlas.persister.save(resource: resource)
  end

  private

    # darwin_core#destroy answers 404 for a Work with no record.
    def scratch_dwc!(work)
      Work.find(work.noid).darwin_core_xml = File.read(DWC)
    end

    def build_work!
      @work = described!(public_work! { |work| grant_work!(work) }, MARKERS[:work])
    end

    # The three ways a Work grants edit beyond the staff group: a named
    # editor, an edit group, and its depositor.
    def grant_work!(work)
      work.edit_users  = [ACCOUNTS[:editor][:nuid]]
      work.edit_groups = Array(work.edit_groups) + [EDITOR_GROUP]
      work.depositor   = ACCOUNTS[:owner][:nuid]
    end

    # Granted after the Work exists, so the Work does not inherit it: the
    # curator edits the containers and not what is in them.
    def curate!(container)
      container = Resource.find(container.noid)
      container.edit_users = Array(container.edit_users) + [ACCOUNTS[:curator][:nuid]]
      Atlas.persister.save(resource: container)
    end

    # The Work readable by one group, which only the group reader and the
    # Work's editors may read.
    def group_read!
      resource = Work.find(work.noid)
      resource.read_groups = [READER_GROUP]
      Atlas.persister.save(resource: resource)
    end

    # A Collection purged, so its NOID answers as removed rather than unknown.
    def purged!
      ResourcePurger.call(resource: Collection.find(empty_collection.noid))
    end

    # A Blob detached from its FileSet: no Work answers for it, so only the
    # admin reads it.
    def unattached!
      parent = FileSet.find(file_set.noid)
      parent.member_ids = Array(parent.member_ids) - [blob.id]
      Atlas.persister.save(resource: parent)
    end

    def build_leaves!
      @blob = BlobCreator.call(work_id: work.noid, original_filename: "#{MARKERS[:blob]}.bin", path: FIXTURE.to_s)
      @file_set = blob.parent
      @delegate = DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name,
                                       uri: "https://iiif.example/#{MARKERS[:delegate]}.jpg")
      @gated_delegate = DelegateCreator.call(resource_id: work.id, use: Role.large_image.name,
                                             uri: "https://iiif.example/gated-#{MARKERS[:gated_delegate]}.jpg")
    end

    def build_containers!
      @empty_collection = described!(CollectionCreator.call(parent_id: community.noid), MARKERS[:empty_collection])
      sub = CommunityCreator.call(parent_id: community.noid)
      sub.publicize
      @sub_community = described!(Atlas.persister.save(resource: sub), MARKERS[:sub_community])
    end

    def public_work!
      work = WorkCreator.call(parent_id: collection.noid)
      work.publicize
      yield work if block_given?
      Atlas.persister.save(resource: work)
    end

    def described!(resource, marker)
      set_mods_abstract!(resource, marker)
      Atlas.persister.save(resource: resource)
    end
end

# The callers both matrices share, built from MatrixTree::ACCOUNTS. Each
# caller is one credential path: a signed assertion unless named otherwise.
RSpec.shared_context 'access matrix callers' do
  let!(:guest) do
    User.find_by(role: :guest) ||
      User.create!(email: 'guest-matrix@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000001', name: 'User, Guest', role: :guest)
  end
  let!(:admin) { ensure_default_admin! }
  let(:system_user) { fixture_user(:system, '000000000') }
  let(:fixity_user) { fixture_user(:fixity_checker, User::FIXITY_CHECKER_NUID) }
  # A matrix with callers of its own names them here.
  let(:extra_accounts) { {} }
  let(:users) do
    MatrixTree::ACCOUNTS.merge(extra_accounts).to_h do |tier, account|
      [tier, User.create!(email: "#{tier}-matrix@example.invalid", password: SecureRandom.hex(16),
                          name: "Matrix, #{tier.to_s.titleize}", **account)]
    end.merge(guest: guest, admin: admin)
  end

  def fixture_user(role, nuid)
    User.find_by(role: role) ||
      User.create!(email: "#{role}-matrix@example.invalid", password: SecureRandom.hex(16), nuid: nuid,
                   name: role.to_s.titleize, role: role)
  end

  def headers_for(tier)
    signed_auth_headers(nil)
    AccessMatrixFixtures::CREDENTIALS.fetch(tier) { ->(ctx) { ctx.assertion_headers(ctx.users[tier]) } }.call(self)
  end

  def assertion_headers(user, obo: nil)
    { 'Authorization' => "Bearer #{DefaultAuthHeaders.assertion_for(user.nuid, obo: obo&.nuid)}" }
  end

  # The backend credentials, each paired with its own fixture account.
  def token_headers(credential, user)
    allow(Rails.application.credentials).to receive(credential).and_return("matrix-#{credential}")
    { 'Authorization' => "Bearer matrix-#{credential}", 'User' => "NUID #{user.nuid}" }
  end

  # A personal token as POST /nuid mints it, read-only when asked.
  def jwt_headers(user, read_only: false)
    payload = Warden::JWTAuth::PayloadUserHelper.payload_for_user(user, :user).merge('aud' => nil)
    payload['read_only'] = true if read_only
    { 'Authorization' => "Bearer #{Warden::JWTAuth::TokenEncoder.new.call(payload)}" }
  end
end
