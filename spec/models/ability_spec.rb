# frozen_string_literal: true

require 'rails_helper'
require 'cancan/matchers'

# Role × (resource, action) coverage for the Ability layer. One describe
# block per principal role. The Cerberus-side Ability is its own concern and
# tested over there; this file is the Atlas-wire matrix only.
RSpec.describe Ability do
  def build_user(role:, **attrs)
    User.create!(
      email:    "#{role}-#{SecureRandom.hex(4)}@example.invalid",
      password: SecureRandom.hex(16),
      nuid:     attrs.fetch(:nuid, SecureRandom.hex(5)),
      name:     attrs.fetch(:name, role.to_s.titlecase),
      role:     role,
      groups:   attrs.fetch(:groups, [])
    )
  end

  # Need at least one :guest row in the DB for the nil-user fallback path —
  # the Ability constructor calls User.find_by_role(:guest) when given nil.
  let!(:guest_fixture) do
    User.create!(email: 'guest@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000001', name: 'User, Guest', role: :guest)
  end

  describe 'nil user fallback' do
    subject { described_class.new(nil) }

    it 'resolves to the :guest fixture (read floor only)' do
      expect(subject).to     be_able_to(:read, Resource)
      expect(subject).not_to be_able_to(:create, Work)
    end
  end

  describe 'the :anonymous principal' do
    let(:user) { build_user(role: :anonymous, nuid: '000000099') }
    subject { described_class.new(user) }

    # Floor: no abilities at all. require_auth 401s before Ability is reached;
    # this asserts the belt-and-suspenders early-return.
    it { is_expected.not_to be_able_to(:read,   Resource) }
    it { is_expected.not_to be_able_to(:read,   User) }
    it { is_expected.not_to be_able_to(:create, Work) }
  end

  describe 'the :guest principal' do
    let(:user) { build_user(role: :guest, nuid: '000000099') }
    subject { described_class.new(user) }

    it { is_expected.to     be_able_to(:read,    Resource) }
    it { is_expected.to     be_able_to(:read,    User) }
    it { is_expected.not_to be_able_to(:create,  Work) }
    it { is_expected.not_to be_able_to(:create,  Community) }
    it { is_expected.not_to be_able_to(:create,  Collection) }
    it { is_expected.not_to be_able_to(:create,  FileSet) }
    it { is_expected.not_to be_able_to(:create,  Blob) }
    it { is_expected.not_to be_able_to(:preview, Resource) }
    it { is_expected.not_to be_able_to(:provision, User) }
    it { is_expected.not_to be_able_to(:mint_token, User) }
    it { is_expected.not_to be_able_to(:read,    AuditEvent) }
    it { is_expected.not_to be_able_to(:reset,   :maintenance) }

    # Sets: guests ride the per-row :read rule (public only — the CERES
    # case) and never create or mutate.
    it { is_expected.to     be_able_to(:read,   Compilation.new(read_groups: ['public'])) }
    it { is_expected.not_to be_able_to(:read,   Compilation.new) }
    it { is_expected.not_to be_able_to(:create, Compilation) }
    it { is_expected.not_to be_able_to(:update, Compilation.new(read_groups: ['public'])) }
  end

  describe 'the :system principal' do
    let(:user) { build_user(role: :system, nuid: '000000000') }
    subject { described_class.new(user) }

    # Explicit allowlist: User provisioning, JWT mint, container-create
    # carve-out, read floor.
    it { is_expected.to     be_able_to(:provision,  User) }
    it { is_expected.to     be_able_to(:mint_token, User) }
    it { is_expected.to     be_able_to(:read,       User) }
    it { is_expected.to     be_able_to(:read,       Resource) }
    it { is_expected.to     be_able_to(:create,     Community) }
    it { is_expected.to     be_able_to(:create,     Collection) }
    # Operational Solr re-projection is a :system-tier action.
    it { is_expected.to     be_able_to(:reindex,    Resource) }
    # Person curation (create/edit authority + manage affiliations) is :system + admin.
    it { is_expected.to     be_able_to(:create,     Person) }
    it { is_expected.to     be_able_to(:update,     Person.new) }

    # The rule the piece-2 reject_system_principal sprinkle encoded by hand:
    # :system cannot author Works or mutate any container resource.
    it { is_expected.not_to be_able_to(:create,     Work) }
    it { is_expected.not_to be_able_to(:create,     Compilation) }
    it { is_expected.not_to be_able_to(:read,       Compilation.new(read_groups: ['public'])) }
    it { is_expected.not_to be_able_to(:update,     Community.new) }
    it { is_expected.not_to be_able_to(:update,     Collection.new) }
    it { is_expected.not_to be_able_to(:tombstone,  Community.new) }
    it { is_expected.not_to be_able_to(:tombstone,  Collection.new) }
    it { is_expected.not_to be_able_to(:destroy,    Work.new) }
    it { is_expected.not_to be_able_to(:reset,      :maintenance) }
    it { is_expected.not_to be_able_to(:read,       AuditEvent) }

    # Showcase publishing: :link_member on a featured Collection is granted
    # unconditionally (the Collection-side scope), but the Work-side grant
    # requires an on_behalf_of target matching the Work's depositor — absent
    # here, so even a featured Collection doesn't unlock it.
    it { is_expected.to     be_able_to(:link_member, Collection.new(featured: true)) }
    it { is_expected.not_to be_able_to(:link_member, Collection.new(featured: false)) }
    it { is_expected.not_to be_able_to(:link_member, Work.new(depositor: '000000123')) }
  end

  describe 'the :system principal, scoped to an on_behalf_of target (showcase publishing)' do
    let(:user)          { build_user(role: :system, nuid: '000000000') }
    let(:depositor_nuid) { '000000123' }
    subject { described_class.new(user, on_behalf_of: depositor_nuid) }

    it 'grants :link_member on a Work owned by the on_behalf_of target' do
      expect(subject).to be_able_to(:link_member, Work.new(depositor: depositor_nuid))
    end

    it 'denies :link_member on a Work owned by someone else' do
      expect(subject).not_to be_able_to(:link_member, Work.new(depositor: '000000999'))
    end

    it 'still requires the target Collection to be featured' do
      expect(subject).to     be_able_to(:link_member, Collection.new(featured: true))
      expect(subject).not_to be_able_to(:link_member, Collection.new(featured: false))
    end

    it 'grants no other structural mutation on the owned Work' do
      own_work = Work.new(depositor: depositor_nuid)
      expect(subject).not_to be_able_to(:update, own_work)
      expect(subject).not_to be_able_to(:reparent,  own_work)
      expect(subject).not_to be_able_to(:destroy,   own_work)
    end
  end

  # :standard, :loader, :privileged collapse to identical Atlas-wire surfaces.
  # Their UI-tier differentiation lives in Cerberus's Ability. The three
  # describe blocks below share a shape; the duplication is deliberate so a
  # future role split lands cleanly into separate blocks.
  %i[standard loader privileged].each do |role_sym|
    describe "the :#{role_sym} principal" do
      let(:user) { build_user(role: role_sym, nuid: "00000005#{role_sym.length}") }
      subject { described_class.new(user) }

      it { is_expected.to     be_able_to(:read,    Resource) }
      it { is_expected.to     be_able_to(:read,    User) }
      it { is_expected.to     be_able_to(:create,  Work) }
      it { is_expected.to     be_able_to(:create,  Community) }
      it { is_expected.to     be_able_to(:create,  Collection) }
      it { is_expected.to     be_able_to(:create,  Compilation) }
      it { is_expected.to     be_able_to(:create,  FileSet) }
      it { is_expected.to     be_able_to(:create,  Blob) }
      it { is_expected.to     be_able_to(:update,  FileSet) }
      it { is_expected.to     be_able_to(:update,  Blob) }
      it { is_expected.to     be_able_to(:preview, Resource) }

      # Reindex is operational (:system / admin only), not a user action.
      it { is_expected.not_to be_able_to(:reindex,    Resource) }
      # Person curation is :system + admin — a standard human cannot.
      it { is_expected.not_to be_able_to(:create,     Person) }
      it { is_expected.not_to be_able_to(:update,     Person.new) }
      it { is_expected.not_to be_able_to(:destroy,    Work.new) }
      it { is_expected.not_to be_able_to(:destroy,    FileSet) }
      it { is_expected.not_to be_able_to(:destroy,    Blob) }
      it { is_expected.not_to be_able_to(:provision,  User) }
      it { is_expected.not_to be_able_to(:mint_token, User) }
      it { is_expected.not_to be_able_to(:read,       AuditEvent) }
      it { is_expected.not_to be_able_to(:reset,      :maintenance) }
    end
  end

  # Devolved-admin tier: :privileged role + Permissions::ADMIN_GROUP, jointly
  # (apply_admin_delegate_abilities). Neither the role nor the group alone is
  # sufficient — the two negative-control describe blocks below cover each
  # half independently. Grants are unconditional (system-wide), not scoped to
  # edit_users/edit_groups, and deliberately narrow: :reparent on Work,
  # Collection, and Community, :create AuditEvent, and :read_versions on
  # Blob — not the full :admin wildcard and not :link_member or the generic
  # :read on AuditEvent.
  describe 'the devolved-admin tier (:privileged + Permissions::ADMIN_GROUP)' do
    let(:user) { build_user(role: :privileged, nuid: '000000002', groups: [Permissions::ADMIN_GROUP]) }
    subject { described_class.new(user) }

    let(:stranger_work)       { Work.new(edit_users: ['000000999'], edit_groups: ['somebody:else']) }
    let(:stranger_collection) { Collection.new(edit_users: ['000000999'], edit_groups: ['somebody:else']) }
    let(:stranger_community)  { Community.new(edit_users: ['000000999'], edit_groups: ['somebody:else']) }

    it 'grants :reparent on Work, Collection, and Community, unconditionally (not scoped to edit rights)' do
      expect(subject).to be_able_to(:reparent, stranger_work)
      expect(subject).to be_able_to(:reparent, stranger_collection)
      expect(subject).to be_able_to(:reparent, stranger_community)
    end

    it 'grants :create AuditEvent (unblocks the impersonation session-start audit write)' do
      expect(subject).to be_able_to(:create, AuditEvent)
    end

    it 'grants :read_versions on Blob without opening the generic audit-history read' do
      expect(subject).to     be_able_to(:read_versions, Blob)
      expect(subject).not_to be_able_to(:read, AuditEvent)
    end

    it 'grants none of the other admin-only structural mutations' do
      expect(subject).not_to be_able_to(:link_member, Work.new)
      expect(subject).not_to be_able_to(:link_member, stranger_collection)
      expect(subject).not_to be_able_to(:destroy,     Work.new)
      expect(subject).not_to be_able_to(:manage,      :all)
    end
  end

  describe 'devolved-admin tier negative control: :privileged role without the admin group' do
    let(:user) { build_user(role: :privileged, nuid: '000000006', groups: [Permissions::STAFF_EDIT_GROUP]) }
    subject { described_class.new(user) }

    it 'denies :reparent, :create AuditEvent, and :read_versions Blob' do
      expect(subject).not_to be_able_to(:reparent,      Collection.new)
      expect(subject).not_to be_able_to(:reparent,      Community.new)
      expect(subject).not_to be_able_to(:create,        AuditEvent)
      expect(subject).not_to be_able_to(:read_versions, Blob)
    end
  end

  describe 'devolved-admin tier negative control: the admin group without the :privileged role' do
    %i[standard loader].each do |role_sym|
      it "denies :reparent for :#{role_sym} + the admin group" do
        user = build_user(role: role_sym, nuid: SecureRandom.hex(5), groups: [Permissions::ADMIN_GROUP])
        ability = described_class.new(user)
        expect(ability).not_to be_able_to(:reparent,      Collection.new)
        expect(ability).not_to be_able_to(:create,        AuditEvent)
        expect(ability).not_to be_able_to(:read_versions, Blob)
      end
    end
  end

  describe 'group ACL block form' do
    let(:user) do
      build_user(role: :standard, nuid: '000000777',
                 groups: ['northeastern:drs:dataset-editors'])
    end
    subject { described_class.new(user) }

    let(:other_users_work) do
      Work.new(edit_users: ['000000999'], edit_groups: ['somebody:else'])
    end
    let(:work_via_edit_user) do
      Work.new(edit_users: [user.nuid], edit_groups: [])
    end
    let(:work_via_edit_group) do
      Work.new(edit_users: [], edit_groups: user.groups)
    end

    it 'denies :update on a Work the user has no ACL access to' do
      expect(subject).not_to be_able_to(:update,    other_users_work)
      expect(subject).not_to be_able_to(:tombstone, other_users_work)
      expect(subject).not_to be_able_to(:restore,   other_users_work)
    end

    it 'grants :update / :tombstone / :restore when the user is in edit_users' do
      expect(subject).to be_able_to(:update,    work_via_edit_user)
      expect(subject).to be_able_to(:tombstone, work_via_edit_user)
      expect(subject).to be_able_to(:restore,   work_via_edit_user)
    end

    it 'grants :update / :tombstone / :restore when the user shares an edit_group' do
      expect(subject).to be_able_to(:update,    work_via_edit_group)
      expect(subject).to be_able_to(:tombstone, work_via_edit_group)
      expect(subject).to be_able_to(:restore,   work_via_edit_group)
    end

    it 'aliases :update_thumbnails / :update_image_derivatives / :update_derivative_permissions / :complete to :update' do
      expect(subject).to     be_able_to(:update_thumbnails,            work_via_edit_user)
      expect(subject).to     be_able_to(:update_image_derivatives,     work_via_edit_user)
      expect(subject).to     be_able_to(:update_derivative_permissions, work_via_edit_user)
      expect(subject).to     be_able_to(:complete,                     work_via_edit_user)
      expect(subject).not_to be_able_to(:update_thumbnails,            other_users_work)
      expect(subject).not_to be_able_to(:update_derivative_permissions, other_users_work)
    end

    it 'does NOT grant :reparent or :link_member — structural mutations are admin-only' do
      # Edit-rights is deliberately insufficient for re-parenting a node or
      # linking a Work into additional Collections; both are admin-only and
      # ride solely on the admin wildcard.
      expect(subject).not_to be_able_to(:reparent,    work_via_edit_user)
      expect(subject).not_to be_able_to(:reparent,    work_via_edit_group)
      expect(subject).not_to be_able_to(:link_member, work_via_edit_user)
      expect(subject).not_to be_able_to(:link_member, work_via_edit_group)
    end

    it 'applies the same shape to Collection and Community' do
      collection = Collection.new(edit_users: [user.nuid], edit_groups: [])
      community  = Community.new(edit_users: [], edit_groups: user.groups)

      expect(subject).to be_able_to(:update,    collection)
      expect(subject).to be_able_to(:tombstone, community)
    end
  end

  # Compilations diverge from the `can :read, Resource` floor — visibility
  # is per-row (owner / ACL / public). Write side is owner + explicit grants
  # only; there is deliberately NO staff default (F2).
  describe 'Compilation per-row rules' do
    let(:user) do
      build_user(role: :standard, nuid: '000000778',
                 groups: ['northeastern:drs:dataset-editors'])
    end
    subject { described_class.new(user) }

    let(:own_set)      { Compilation.new(depositor: user.nuid) }
    let(:stranger_set) { Compilation.new(depositor: '000000999') }
    let(:public_set)   { Compilation.new(depositor: '000000999', read_groups: ['public']) }

    it 'grants the owner read / update / destroy' do
      expect(subject).to be_able_to(:read,    own_set)
      expect(subject).to be_able_to(:update,  own_set)
      expect(subject).to be_able_to(:destroy, own_set)
    end

    it 'denies a stranger everything on a private set' do
      expect(subject).not_to be_able_to(:read,    stranger_set)
      expect(subject).not_to be_able_to(:update,  stranger_set)
      expect(subject).not_to be_able_to(:destroy, stranger_set)
    end

    it 'grants :read (only) on a public set' do
      expect(subject).to     be_able_to(:read,   public_set)
      expect(subject).not_to be_able_to(:update, public_set)
    end

    it 'grants :read via read_groups membership' do
      set = Compilation.new(depositor: '000000999', read_groups: user.groups)
      expect(subject).to be_able_to(:read, set)
    end

    it 'grants write via edit_users / edit_groups (duck-typed group_acl_grants?)' do
      via_user  = Compilation.new(depositor: '000000999', edit_users: [user.nuid])
      via_group = Compilation.new(depositor: '000000999', edit_groups: user.groups)

      expect(subject).to be_able_to(:update,  via_user)
      expect(subject).to be_able_to(:destroy, via_group)
      expect(subject).to be_able_to(:read,    via_user)
    end

    it 'admin wildcard covers a stranger private set' do
      admin = described_class.new(build_user(role: :admin, nuid: '000000005'))
      expect(admin).to be_able_to(:read,    stranger_set)
      expect(admin).to be_able_to(:update,  stranger_set)
      expect(admin).to be_able_to(:destroy, stranger_set)
    end
  end

  describe 'the :admin principal' do
    let(:user) { build_user(role: :admin, nuid: '000000004') }
    subject { described_class.new(user) }

    # Wildcard.
    it { is_expected.to be_able_to(:manage,     :all) }
    it { is_expected.to be_able_to(:read,       Resource) }
    it { is_expected.to be_able_to(:create,     Work) }
    it { is_expected.to be_able_to(:destroy,    Work.new) }
    it { is_expected.to be_able_to(:destroy,    FileSet) }
    it { is_expected.to be_able_to(:read,       AuditEvent) }
    it { is_expected.to be_able_to(:reset,      :maintenance) }
    it { is_expected.to be_able_to(:provision,  User) }
    it { is_expected.to be_able_to(:mint_token, User) }

    it 'bypasses group ACL for resources the admin is not in edit_users/groups of' do
      stranger_work = Work.new(edit_users: ['000000999'], edit_groups: ['somebody:else'])
      expect(subject).to be_able_to(:update, stranger_work)
      expect(subject).to be_able_to(:tombstone, stranger_work)
    end

    it 'grants the admin-only structural mutations :reparent and :link_member' do
      stranger_work = Work.new(edit_users: ['000000999'], edit_groups: ['somebody:else'])
      expect(subject).to be_able_to(:reparent,    stranger_work)
      expect(subject).to be_able_to(:link_member, stranger_work)
    end
  end
end
