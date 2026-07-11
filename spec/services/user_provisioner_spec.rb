# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserProvisioner do
  describe '.call when no account exists for the email' do
    it 'creates a new account keyed on email' do
      user = described_class.call(
        email:       'jane@example.edu',
        nuid:        '001234567',
        groups:      ['northeastern:staff', 'drs:editors'],
        name:        'Jane Doe',
        affiliation: 'staff'
      )

      expect(user).to be_persisted
      expect(user.email).to eq('jane@example.edu')
      expect(user.nuid).to eq('001234567')
      expect(user.name).to eq('Jane Doe')
      expect(user.affiliation).to eq('staff')
      expect(user.role).to eq('standard')
      expect(user.groups).to eq(['northeastern:staff', 'drs:editors'])
    end
  end

  describe '.call when an account already exists for the email' do
    let!(:existing) do
      User.create!(
        email:    'jane@example.edu',
        nuid:     '001234567',
        name:     'Old Name',
        password: SecureRandom.hex(16),
        role:     :standard,
        groups:   ['stale:group']
      )
    end

    it 'returns the same record (idempotent on email)' do
      user = described_class.call(email: 'jane@example.edu', groups: [])
      expect(user.id).to eq(existing.id)
    end

    it 'replaces (does not merge) the groups array' do
      user = described_class.call(email: 'jane@example.edu', groups: ['fresh:group'])
      expect(user.groups).to eq(['fresh:group'])
      expect(user.groups).not_to include('stale:group')
    end

    it 'updates nuid/name/affiliation when supplied, leaves them otherwise' do
      described_class.call(email: 'jane@example.edu', groups: [], name: 'New Name', affiliation: 'staff')
      expect(existing.reload.name).to eq('New Name')
      expect(existing.affiliation).to eq('staff')

      described_class.call(email: 'jane@example.edu', groups: [])
      expect(existing.reload.name).to eq('New Name') # untouched when omitted
    end
  end

  # The core of the account-switching feature: two logins (staff + student)
  # share one NUID but present a different email each, so keying on email keeps
  # them as distinct accounts instead of collapsing (last-write-wins) on NUID.
  describe '.call with two emails sharing a NUID' do
    it 'creates two distinct accounts under one NUID instead of overwriting' do
      staff = described_class.call(email: 'p@northeastern.edu', nuid: '000000005',
                                   groups: ['g:staff'], affiliation: 'staff')
      student = described_class.call(email: 'p@husky.neu.edu', nuid: '000000005',
                                     groups: ['g:student'], affiliation: 'student')

      expect(staff.id).not_to eq(student.id)
      expect(User.where(nuid: '000000005').count).to eq(2)
      expect(staff.groups).to eq(['g:staff'])
      expect(student.groups).to eq(['g:student'])
    end
  end
end
