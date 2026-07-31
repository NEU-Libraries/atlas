# frozen_string_literal: true

require 'rails_helper'

RSpec.describe User do
  describe 'role enum' do
    it 'orders by privilege gradient' do
      expect(described_class.roles).to eq(
        'anonymous'  => 0,
        'guest'      => 1,
        'standard'   => 2,
        'loader'     => 3,
        'privileged' => 4,
        'admin'      => 5,
        'system'     => 6
      )
    end

    it 'defaults newly built users to :standard' do
      expect(described_class.new.role).to eq('standard')
    end
  end

  describe '.find_by_role' do
    # Non-human bookend rows are seeded once and looked up by role, never by NUID.
    let!(:anonymous) do
      described_class.create!(email: 'anon@example.invalid', password: SecureRandom.hex(16),
                              nuid: '000000099', name: 'User, Anonymous', role: :anonymous)
    end
    let!(:system_user) do
      described_class.create!(email: 'sys@example.invalid', password: SecureRandom.hex(16),
                              nuid: '000000000', name: 'User, System', role: :system)
    end
    let!(:guest) do
      described_class.create!(email: 'guest@example.invalid', password: SecureRandom.hex(16),
                              nuid: '000000001', name: 'User, Guest', role: :guest)
    end
    let!(:loader) do
      described_class.create!(email: 'loader@example.invalid', password: SecureRandom.hex(16),
                              nuid: '000000003', name: 'Loader, Marcom', role: :loader)
    end
    let!(:privileged) do
      described_class.create!(email: 'priv@example.invalid', password: SecureRandom.hex(16),
                              nuid: '000000002', name: 'Doe, Jane', role: :privileged)
    end
    let!(:admin) do
      described_class.create!(email: 'admin@example.invalid', password: SecureRandom.hex(16),
                              nuid: '000000004', name: 'User, Admin', role: :admin)
    end

    it 'resolves each role to its fixture row' do
      expect(described_class.find_by(role: :anonymous)).to  eq(anonymous)
      expect(described_class.find_by(role: :system)).to     eq(system_user)
      expect(described_class.find_by(role: :guest)).to      eq(guest)
      expect(described_class.find_by(role: :loader)).to     eq(loader)
      expect(described_class.find_by(role: :privileged)).to eq(privileged)
      expect(described_class.find_by(role: :admin)).to      eq(admin)
    end

    it 'exposes predicate methods for the new roles' do
      expect(anonymous).to  be_anonymous
      expect(loader).to     be_loader
      expect(privileged).to be_privileged
    end
  end

  # The devolved-admin tier is the conjunction of a role and a group; each half
  # alone must not qualify.
  describe '#admin_delegate?' do
    def user_with(role:, groups:)
      described_class.new(role: role, groups: groups)
    end

    it 'is true for :privileged carrying the admin group' do
      expect(user_with(role: :privileged, groups: [Permissions::ADMIN_GROUP])).to be_admin_delegate
    end

    it 'is false for :privileged without the group' do
      expect(user_with(role: :privileged, groups: [Permissions::STAFF_EDIT_GROUP])).not_to be_admin_delegate
      expect(user_with(role: :privileged, groups: [])).not_to be_admin_delegate
    end

    it 'is false for the group without the :privileged role' do
      %i[standard loader admin].each do |role|
        expect(user_with(role: role, groups: [Permissions::ADMIN_GROUP])).not_to be_admin_delegate
      end
    end
  end

  # Multiple accounts per NUID (a person's staff/student logins share the NUID
  # but each has its own email + group set).
  describe 'accounts per NUID' do
    let(:nuid) { '000000005' }
    let!(:staff) do
      described_class.create!(email: 'p@northeastern.edu', nuid: nuid, name: 'P',
                              password: SecureRandom.hex(16), role: :standard,
                              affiliation: 'staff', groups: ['g:staff'])
    end
    let!(:student) do
      described_class.create!(email: 'p@husky.neu.edu', nuid: nuid, name: 'P',
                              password: SecureRandom.hex(16), role: :standard,
                              affiliation: 'student', groups: ['g:student'])
    end

    describe '.accounts_for' do
      it 'returns every account sharing the NUID, oldest first' do
        expect(described_class.accounts_for(nuid).to_a).to eq([staff, student])
      end
    end

    describe '.resolve_account' do
      it 'selects the exact account when an email is given' do
        expect(described_class.resolve_account(nuid: nuid, email: 'p@husky.neu.edu')).to eq(student)
      end

      it 'returns nil when the email is not one of the NUID\'s accounts' do
        expect(described_class.resolve_account(nuid: nuid, email: 'stranger@x.edu')).to be_nil
      end

      it 'falls back to the preferred account when no email is given' do
        student.make_preferred!
        expect(described_class.resolve_account(nuid: nuid)).to eq(student)
      end

      it 'falls back to the oldest account when none is preferred' do
        expect(described_class.resolve_account(nuid: nuid)).to eq(staff)
      end
    end

    describe '#make_preferred!' do
      it 'marks one account preferred and demotes the others (one winner per NUID)' do
        staff.make_preferred!
        student.make_preferred!

        expect(staff.reload.preferred).to be(false)
        expect(student.reload.preferred).to be(true)
        expect(described_class.where(nuid: nuid, preferred: true).count).to eq(1)
      end
    end
  end
end
