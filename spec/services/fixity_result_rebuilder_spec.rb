# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FixityResultRebuilder do
  let(:adapter) { Valkyrie.config.storage_adapter }
  let(:work)    { WorkCreator.call(parent_id: CollectionCreator.call(parent_id: CommunityCreator.call.noid).noid) }

  after { Atlas.persister.wipe! }

  def log(at, result)
    line = { object: "urn:neu-drs:#{work.noid}", checked_at: at, version: 'v1', algorithm: 'sha512', files: 3,
             result: result, findings: [], checker: 'spec-checker 1.0', recorded_by: '000000000' }.to_json
    adapter.append_log(key: work.noid, name: FixityCheckRecorder::LOG_NAME, line: line)
  end

  it "rebuilds an object's row from the newest line in its log" do
    log('2026-10-27T03:00:00Z', 'fail')
    log('2026-09-01T03:00:00Z', 'pass')

    report = described_class.call

    expect(FixityResult.find(work.noid))
      .to have_attributes(checked_at: Time.utc(2026, 10, 27, 3), result: 'fail', version: 'v1')
    expect(report[:corrected]).to be >= 1
  end

  it 'skips a damaged line and keeps the rest' do
    log('2026-10-27T03:00:00Z', 'pass')
    adapter.append_log(key: work.noid, name: FixityCheckRecorder::LOG_NAME, line: '{not json')

    expect(described_class.call[:unreadable_lines]).to be >= 1
    expect(FixityResult.find(work.noid).result).to eq('pass')
  end

  it 'drops a row whose object has no log' do
    FixityResult.set!(key: 'nosuchkey', checked_at: Time.current, result: 'pass', version: 'v1', checker: 'x')
    described_class.call
    expect(FixityResult.where(object_key: 'nosuchkey')).not_to exist
  end

  it 'changes nothing when the rows already match the logs' do
    log('2026-10-27T03:00:00Z', 'pass')
    described_class.call
    allow(Atlas).to receive(:reindex)

    described_class.call

    expect(Atlas).not_to have_received(:reindex)
  end
end
