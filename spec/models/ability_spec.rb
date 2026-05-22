# frozen_string_literal: true

require 'rails_helper'

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
  end

  describe 'the :system principal' do
    let(:user) { build_user(role: :system, nuid: '000000000') }
    subject { described_class.new(user) }

    # Explicit allowlist: User provisioning, JWT mint, Q7 container-create
    # carve-out, read floor.
    it { is_expected.to     be_able_to(:provision,  User) }
    it { is_expected.to     be_able_to(:mint_token, User) }
    it { is_expected.to     be_able_to(:read,       User) }
    it { is_expected.to     be_able_to(:read,       Resource) }
    it { is_expected.to     be_able_to(:create,     Community) }
    it { is_expected.to     be_able_to(:create,     Collection) }

    # The rule the piece-2 reject_system_principal sprinkle encoded by hand:
    # :system cannot author Works or mutate any container resource.
    it { is_expected.not_to be_able_to(:create,     Work) }
    it { is_expected.not_to be_able_to(:update,     Community.new) }
    it { is_expected.not_to be_able_to(:update,     Collection.new) }
    it { is_expected.not_to be_able_to(:tombstone,  Community.new) }
    it { is_expected.not_to be_able_to(:tombstone,  Collection.new) }
    it { is_expected.not_to be_able_to(:destroy,    Work.new) }
    it { is_expected.not_to be_able_to(:reset,      :maintenance) }
    it { is_expected.not_to be_able_to(:read,       AuditEvent) }
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
      it { is_expected.to     be_able_to(:create,  FileSet) }
      it { is_expected.to     be_able_to(:create,  Blob) }
      it { is_expected.to     be_able_to(:update,  FileSet) }
      it { is_expected.to     be_able_to(:update,  Blob) }
      it { is_expected.to     be_able_to(:preview, Resource) }

      it { is_expected.not_to be_able_to(:destroy,    Work.new) }
      it { is_expected.not_to be_able_to(:destroy,    FileSet) }
      it { is_expected.not_to be_able_to(:destroy,    Blob) }
      it { is_expected.not_to be_able_to(:provision,  User) }
      it { is_expected.not_to be_able_to(:mint_token, User) }
      it { is_expected.not_to be_able_to(:read,       AuditEvent) }
      it { is_expected.not_to be_able_to(:reset,      :maintenance) }
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

    it 'aliases :update_thumbnails / :update_image_derivatives / :complete to :update' do
      expect(subject).to     be_able_to(:update_thumbnails,         work_via_edit_user)
      expect(subject).to     be_able_to(:update_image_derivatives,  work_via_edit_user)
      expect(subject).to     be_able_to(:complete,                  work_via_edit_user)
      expect(subject).not_to be_able_to(:update_thumbnails,         other_users_work)
    end

    it 'applies the same shape to Collection and Community' do
      collection = Collection.new(edit_users: [user.nuid], edit_groups: [])
      community  = Community.new(edit_users: [], edit_groups: user.groups)

      expect(subject).to be_able_to(:update,    collection)
      expect(subject).to be_able_to(:tombstone, community)
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
  end
end
