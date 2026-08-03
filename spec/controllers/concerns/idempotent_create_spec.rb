# frozen_string_literal: true

require 'rails_helper'

describe IdempotentCreate do
  # Minimal host standing in for a controller: mixes in the concern and
  # supplies the request headers and @current_user the helpers read. The
  # helpers are private, so specs reach them via send.
  let(:host_class) do
    Class.new do
      include IdempotentCreate

      attr_accessor :request

      def initialize(user)
        @current_user = user
      end
    end
  end

  let(:user) do
    User.create!(email: "idem-host-#{SecureRandom.hex(4)}@example.invalid",
                 password: SecureRandom.hex(16), nuid: '000000004', role: :admin)
  end
  let(:key) { SecureRandom.uuid }

  subject(:host) do
    h = host_class.new(user)
    h.request = ActionDispatch::TestRequest.create('HTTP_IDEMPOTENCY_KEY' => key)
    h
  end

  describe '#find_idempotency_record' do
    it 'matches a row of the same class' do
      row = IdempotencyKey.create!(user: user, key: key, resource_type: 'Work', resource_noid: 'abc1234')

      expect(host.send(:find_idempotency_record, Work)).to eq(row)
    end

    # The batch loader's case: the Work's key must not make the Blob a replay.
    it 'ignores a row of a different class' do
      IdempotencyKey.create!(user: user, key: key, resource_type: 'Work', resource_noid: 'abc1234')

      expect(host.send(:find_idempotency_record, Blob)).to be_nil
    end
  end

  describe '#record_idempotency_key!' do
    it 'records one row per class for a single key' do
      host.send(:record_idempotency_key!, 'abc1234', Work)
      host.send(:record_idempotency_key!, 'def5678', Blob)

      expect(IdempotencyKey.where(key: key).pluck(:resource_type, :resource_noid))
        .to contain_exactly(%w[Work abc1234], %w[Blob def5678])
    end

    # Bookkeeping must never fail a create that already landed in Postgres,
    # Solr and OCFL: raising would report a successful create as an error and
    # the caller would retry it into a second copy. A concurrent request that
    # wins the race is the only way to get here once the scope is right.
    it 'swallows a lost uniqueness race' do
      IdempotencyKey.create!(user: user, key: key, resource_type: 'Work', resource_noid: 'winner1')

      expect { host.send(:record_idempotency_key!, 'loser12', Work) }.not_to raise_error
      expect(IdempotencyKey.where(key: key).pluck(:resource_noid)).to eq(['winner1'])
    end

    it 'still raises a validation failure that is not about the key' do
      expect { host.send(:record_idempotency_key!, nil, Work) }
        .to raise_error(ActiveRecord::RecordInvalid, /Resource noid/)
    end

    it 'is a no-op without the header' do
      host.request = ActionDispatch::TestRequest.create

      expect { host.send(:record_idempotency_key!, 'abc1234', Work) }
        .not_to change(IdempotencyKey, :count)
    end
  end
end
