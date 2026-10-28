# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NoidInUse do
  let(:work) { WorkCreator.call(parent_id: CollectionCreator.call(parent_id: CommunityCreator.call.noid).noid) }

  after { Atlas.persister.wipe! }

  # Hands the minter a fixed sequence, so a spec can put a used NOID first, then
  # lets the real minter serve every later draw.
  def mint_sequence(*noids)
    queue = noids.dup
    allow(Minter.minter).to receive(:next_id).and_wrap_original { |original| queue.shift || original.call }
  end

  def fresh_noid
    loop do
      candidate = "zz#{SecureRandom.alphanumeric(7).downcase}"
      return candidate unless Valkyrie.config.storage_adapter.object_exists?(key: candidate)
    end
  end

  it 'is true for a NOID whose OCFL object exists, and logs it' do
    allow(Rails.logger).to receive(:warn)

    expect(described_class.call(work.noid)).to be(true)
    expect(Rails.logger).to have_received(:warn).with(/#{work.noid} already has an OCFL object/)
  end

  it 'is false for a NOID no root holds' do
    expect(described_class.call(fresh_noid)).to be(false)
  end

  describe 'the minter' do
    # A rewound minter offers a NOID that is already on disk; the hook makes it
    # draw again rather than append to that object.
    it 'passes over a NOID whose object exists' do
      used = work.noid
      fresh = fresh_noid
      mint_sequence(used, fresh)

      expect(Minter.mint).to eq(fresh)
    end

    it "never appends a new resource's versions to an existing object" do
      used = work.noid
      head = Valkyrie.config.storage_adapter.object_versions(key: used).max_by { |v| v.delete_prefix('v').to_i }
      fresh = fresh_noid
      mint_sequence(used, fresh)

      community = CommunityCreator.call

      expect(community.noid).to eq(fresh)
      expect(Valkyrie.config.storage_adapter.object_versions(key: used).max_by { |v| v.delete_prefix('v').to_i })
        .to eq(head)
    end

    # Compilations own no OCFL object, but share the minter and its namespace.
    it 'passes over a used NOID for a Compilation too' do
      used = work.noid
      fresh = fresh_noid
      mint_sequence(used, fresh)
      owner = User.create!(email: 'noid-owner@example.invalid', password: SecureRandom.hex(16),
                           nuid: '000009301', name: 'Owner, Noid', role: :standard)

      expect(Compilation.create!(title: 'Set', depositor: owner.nuid).noid).to eq(fresh)
    end
  end
end
