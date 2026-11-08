# frozen_string_literal: true

# The support files load alphabetically, and this one sorts first.
require_relative 'mods_fixture_helper'

# The fixture tree, the states and the callers that both access matrices run
# against, so the read matrix and the write matrix describe the same world. See
# docs/testing.md.
class MatrixWorld
  include MODSFixtureHelper

  # The states every matrix shares: a resource live, a Work narrowed to its
  # editors, and a tombstone on each type that can carry one.
  STATES = %i[live private work_tombstoned file_set_tombstoned collection_tombstoned community_tombstoned].freeze
  OPERATORS = %i[delegate admin].freeze

  # The subject each state tombstones directly.
  TOMBSTONED = {
    work_tombstoned:       :work,
    file_set_tombstoned:   :file_set,
    collection_tombstoned: :empty_collection,
    community_tombstoned:  :sub_community
  }.freeze

  # The subjects each state withholds. A leaf is withheld by its own tombstone
  # and by its Work's; the Delegate hangs off the Work.
  WITHHELD = {
    live:                  [],
    private:               [],
    work_tombstoned:       %i[work delegate file_set blob],
    file_set_tombstoned:   %i[file_set blob],
    collection_tombstoned: %i[empty_collection],
    community_tombstoned:  %i[sub_community]
  }.freeze

  # The private state narrows the Work's ACL, which its leaves read through.
  PRIVATE_SUBJECTS = %i[work delegate file_set blob].freeze

  # A marker string planted in each subject. Below the operator tiers, no
  # response from any read route may carry the marker of a withheld subject.
  MARKERS = {
    work:             'zqworkmarker',
    delegate:         'zqdelegatemarker',
    blob:             'zqfilemarker',
    empty_collection: 'zqcollectionmarker',
    sub_community:    'zqcommunitymarker'
  }.freeze

  FIXTURE = Rails.root.join('spec/fixtures/files/example.bin')
  DWC     = Rails.root.join('spec/fixtures/files/dwc.xml')

  attr_reader :community, :collection, :work, :blob, :file_set, :delegate, :empty_collection, :sub_community

  # Every route the application draws, framework routes aside, as
  # [route, 'controller#action'].
  def self.routes
    Rails.application.routes.routes.filter_map do |route|
      controller = route.defaults[:controller]
      next if controller.nil? || controller.start_with?('rails/', 'active_storage/', 'action_mailbox/')

      [route, "#{controller}##{route.defaults[:action]}"]
    end
  end

  # The editor holds an edit grant on the Work and nothing else, which is what
  # separates it from the standard caller in every cell.
  def initialize(editor_nuid:)
    @editor_nuid = editor_nuid
  end

  # Every route in a matrix must have something to answer, or a 404 would pass
  # for a refusal. The METS and Darwin Core records give their routes one.
  def build!
    @community  = public_community!
    @collection = CollectionCreator.call(parent_id: community.noid)
    build_work!
    @blob = BlobCreator.call(work_id: work.noid, original_filename: "#{MARKERS[:blob]}.bin", path: FIXTURE.to_s)
    @file_set = blob.parent
    @delegate = DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name,
                                     uri: "https://iiif.example/#{MARKERS[:delegate]}.jpg")
    build_containers!
    WorkMETSRebuilder.call(work: work)
    Work.find(work.noid).darwin_core_xml = File.read(DWC)
    self
  end

  def apply!(state)
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
               when :work             then public_work! { |w| w.edit_users = [@editor_nuid] }.tap { |w| scratch_dwc!(w) }
               when :file_set         then FileSetCreator.call(work_id: work.noid, classification: Classification.generic)
               when :blob             then BlobCreator.call(work_id: work.noid, original_filename: 'scratch.bin',
                                                            path: FIXTURE.to_s)
               when :empty_collection then CollectionCreator.call(parent_id: community.noid)
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
      @work = public_work! do |work|
        work.edit_users = [@editor_nuid]
        work.depositor  = @editor_nuid
      end
      @work = described!(work, MARKERS[:work])
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

# The callers both matrices share. The write matrix adds two tiers the read
# matrix has no use for: :system, and :read_only, the admin on a read-only
# personal token, whose every write must be refused by the token floor.
RSpec.shared_context 'access matrix callers' do
  let!(:guest) do
    User.find_by(role: :guest) ||
      User.create!(email: 'guest-matrix@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000001', name: 'User, Guest', role: :guest)
  end
  let!(:admin) { ensure_default_admin! }
  let(:system_user) do
    User.find_by(role: :system) ||
      User.create!(email: 'system-matrix@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000000', name: 'System', role: :system)
  end
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

  def headers_for(tier)
    case tier
    when :guest     then signed_auth_headers(nil)
    when :system    then system_headers
    when :read_only then read_only_headers(admin)
    else signed_auth_headers(users[tier].nuid)
    end
  end

  def system_headers
    allow(Rails.application.credentials).to receive(:system_token).and_return('matrix-system-token')
    { 'Authorization' => 'Bearer matrix-system-token', 'User' => "NUID #{system_user.nuid}" }
  end

  # A personal token minted with read_only, as POST /nuid mints it.
  def read_only_headers(user)
    signed_auth_headers(nil)
    payload = Warden::JWTAuth::PayloadUserHelper.payload_for_user(user, :user).merge('aud' => nil)
    payload['read_only'] = true
    { 'Authorization' => "Bearer #{Warden::JWTAuth::TokenEncoder.new.call(payload)}" }
  end
end
