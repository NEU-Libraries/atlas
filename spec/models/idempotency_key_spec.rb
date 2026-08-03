# frozen_string_literal: true

require 'rails_helper'

RSpec.describe IdempotencyKey do
  let(:user) do
    User.create!(email: "idem-#{SecureRandom.hex(4)}@example.invalid",
                 password: SecureRandom.hex(16), nuid: '000000004', role: :admin)
  end
  let(:key) { SecureRandom.uuid }

  def record(resource_type, noid: 'abc1234')
    described_class.new(user: user, key: key, resource_type: resource_type, resource_noid: noid)
  end

  describe 'uniqueness of key' do
    # One batch-load row creates a Work and then that Work's Blob under its
    # single key. Both must record: the class is what makes them two operations.
    it 'admits the same key for a different resource type' do
      record('Work').save!

      blob_key = record('Blob', noid: 'def5678')

      expect(blob_key).to be_valid
      expect { blob_key.save! }.not_to raise_error
    end

    it 'rejects the same key for the same resource type' do
      record('Work').save!

      replay = record('Work', noid: 'zzz9999')

      expect(replay).not_to be_valid
      expect(replay.errors[:key]).to be_present
    end

    it 'admits the same key for a different user' do
      record('Work').save!
      other = User.create!(email: "idem-#{SecureRandom.hex(4)}@example.invalid",
                           password: SecureRandom.hex(16), nuid: '000000005', role: :standard)

      expect(described_class.new(user: other, key: key, resource_type: 'Work',
                                 resource_noid: 'yyy8888')).to be_valid
    end
  end

  # The validation and the unique index have to agree — a mismatch is what let
  # a Blob's key pass the replay lookup and then fail its insert, 422-ing a
  # create that had already landed.
  describe 'the backing unique index' do
    it 'covers user_id, key and resource_type' do
      index = ActiveRecord::Base.connection.indexes('idempotency_keys')
                                .find { |i| i.columns.include?('key') }

      expect(index.unique).to be true
      expect(index.columns).to eq(%w[user_id key resource_type])
    end
  end
end
