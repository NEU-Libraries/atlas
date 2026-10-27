# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FixityDueQuery do
  let(:work) { WorkCreator.call(parent_id: CollectionCreator.call(parent_id: CommunityCreator.call.noid).noid) }
  let(:keys) { work.preserved_resources.map(&:noid) }

  after { Atlas.persister.wipe! }

  def checked(key, at)
    FixityResult.advance!(key: key, checked_at: at, result: 'pass', version: 'v1', checker: 'spec')
  end

  def due(before: Time.current)
    described_class.call(limit: 1000, before: before).map(&:key) & keys
  end

  it 'lists every object the ledger holds, never checked first, then oldest check first' do
    newer, older, *unchecked = keys
    checked(newer, Time.utc(2026, 10, 2))
    checked(older, Time.utc(2026, 10, 1))

    expect(due).to eq(unchecked.sort + [older, newer])
  end

  # The sweep passes its own start, so what it has checked drops out.
  it 'leaves out objects checked since checked_before' do
    checked(keys.first, Time.utc(2026, 10, 27, 3))

    expect(due(before: Time.utc(2026, 10, 27, 1))).not_to include(keys.first)
    expect(due(before: Time.utc(2026, 10, 27, 4))).to include(keys.first)
  end

  it "carries each object's bytes from the ledger and its last check" do
    checked(work.noid, Time.utc(2026, 10, 1))
    row = described_class.call(limit: 1000, before: Time.current).find { |r| r.key == work.noid }

    expect(row.bytes).to eq(StorageFootprint.find(work.noid).bytes)
    expect(row.last_checked_at).to eq(Time.utc(2026, 10, 1))
  end
end
