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
      expect(described_class.find_by_role(:anonymous)).to  eq(anonymous)
      expect(described_class.find_by_role(:system)).to     eq(system_user)
      expect(described_class.find_by_role(:guest)).to      eq(guest)
      expect(described_class.find_by_role(:loader)).to     eq(loader)
      expect(described_class.find_by_role(:privileged)).to eq(privileged)
      expect(described_class.find_by_role(:admin)).to      eq(admin)
    end

    it 'exposes predicate methods for the new roles' do
      expect(anonymous).to  be_anonymous
      expect(loader).to     be_loader
      expect(privileged).to be_privileged
    end
  end
end
