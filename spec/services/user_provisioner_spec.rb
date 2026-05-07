# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserProvisioner do
  describe '.call when no User exists for the NUID' do
    it 'creates a new User with the supplied attributes' do
      user = described_class.call(
        nuid:   '001234567',
        groups: ['northeastern:staff', 'drs:editors'],
        email:  'jane@example.edu',
        name:   'Jane Doe'
      )

      expect(user).to be_persisted
      expect(user.nuid).to eq('001234567')
      expect(user.email).to eq('jane@example.edu')
      expect(user.name).to eq('Jane Doe')
      expect(user.role).to eq('standard')
      expect(user.groups).to eq(['northeastern:staff', 'drs:editors'])
    end
  end

  describe '.call when a User already exists for the NUID' do
    let!(:existing) do
      User.create!(
        nuid:     '001234567',
        email:    'old@example.edu',
        name:     'Old Name',
        password: SecureRandom.hex(16),
        role:     :standard,
        groups:   ['stale:group']
      )
    end

    it 'returns the same record (idempotent on NUID)' do
      user = described_class.call(nuid: '001234567', groups: [])
      expect(user.id).to eq(existing.id)
    end

    it 'replaces (does not merge) the groups array' do
      user = described_class.call(
        nuid:   '001234567',
        groups: ['fresh:group']
      )
      expect(user.groups).to eq(['fresh:group'])
      expect(user.groups).not_to include('stale:group')
    end

    it 'updates email and name when supplied' do
      user = described_class.call(
        nuid:   '001234567',
        groups: [],
        email:  'new@example.edu',
        name:   'New Name'
      )
      expect(user.email).to eq('new@example.edu')
      expect(user.name).to eq('New Name')
    end

    it 'leaves email and name untouched when not supplied' do
      user = described_class.call(nuid: '001234567', groups: [])
      expect(user.email).to eq('old@example.edu')
      expect(user.name).to eq('Old Name')
    end
  end

  describe '.call with a duplicate-email collision' do
    let!(:taken) do
      User.create!(
        nuid:     '999999999',
        email:    'taken@example.edu',
        password: SecureRandom.hex(16),
        role:     :standard
      )
    end

    it 'rolls back without creating a partial record' do
      expect {
        described_class.call(
          nuid:   '001234567',
          groups: ['x'],
          email:  'taken@example.edu',
          name:   'Collision'
        )
      }.to raise_error(ActiveRecord::RecordInvalid)

      expect(User.find_by_nuid('001234567')).to be_nil
    end
  end
end
