# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FixityCheckRecorder do
  let(:adapter) { Valkyrie.config.storage_adapter }
  let(:work)    { WorkCreator.call(parent_id: CollectionCreator.call(parent_id: CommunityCreator.call.noid).noid) }

  after { Atlas.persister.wipe! }

  def check(at: '2026-10-27T03:12:09Z', result: 'pass', key: work.noid, version: 'v1')
    findings = result == 'fail' ? [{ 'code' => 'fixity_mismatch', 'path' => 'v1/content/a' }] : []
    FixityCheck.new({ 'object' => "urn:neu-drs:#{key}", 'checked_at' => at, 'version' => version,
                      'algorithm' => 'sha512', 'files' => 3, 'result' => result, 'findings' => findings,
                      'checker' => 'spec-checker 1.0' }, recorded_by: '000000000')
  end

  def solr_doc(resource)
    Atlas.index_adapter.connection.get('select', params: { q:  %(id:"#{resource.id}"),
                                                           fl: 'fixity_checked_at_dtsi,fixity_result_ssi' })
         .dig('response', 'docs', 0)
  end

  it 'logs the check, records it as the latest, and indexes it' do
    recorded = described_class.call(check: check)

    expect(recorded).to include(appended: true, latest: true)
    expect(adapter.read_log(key: work.noid, name: 'fixity.jsonl').map { |l| JSON.parse(l)['result'] }).to eq(['pass'])
    expect(FixityResult.find(work.noid)).to have_attributes(result: 'pass', version: 'v1', checker: 'spec-checker 1.0')
    expect(solr_doc(work)).to eq('fixity_checked_at_dtsi' => '2026-10-27T03:12:09Z', 'fixity_result_ssi' => 'pass')
  end

  # The OAI datestamp is updated_at: a sweep must not make every Work look
  # edited to a harvester.
  it 'leaves the resource row untouched' do
    before = Work.find(work.noid).updated_at
    described_class.call(check: check)
    expect(Work.find(work.noid).updated_at).to eq(before)
  end

  it 'logs an older check but keeps the newer one as the latest' do
    described_class.call(check: check(at: '2026-10-27T03:00:00Z', result: 'fail'))
    recorded = described_class.call(check: check(at: '2026-10-01T03:00:00Z'))

    expect(recorded).to include(appended: true, latest: false)
    expect(FixityResult.find(work.noid).result).to eq('fail')
    expect(adapter.read_log(key: work.noid, name: 'fixity.jsonl').size).to eq(2)
  end

  it 'records a replayed check once' do
    described_class.call(check: check)
    expect(described_class.call(check: check)).to include(appended: false, latest: true)
    expect(adapter.read_log(key: work.noid, name: 'fixity.jsonl').size).to eq(1)
  end

  it 'answers nil for a NOID no resource holds' do
    expect(described_class.call(check: check(key: 'nosuchkey'))).to be_nil
  end

  it 'refuses a version the object does not have, and writes nothing' do
    expect { described_class.call(check: check(version: 'v99')) }
      .to raise_error(Exceptions::FixityCheckError) { |e| expect(e.code).to eq(:unknown_version) }
    expect(adapter.read_log(key: work.noid, name: 'fixity.jsonl')).to be_empty
    expect(FixityResult.where(object_key: work.noid)).not_to exist
  end

  # A Delegate is a resource with a NOID but owns no OCFL object.
  it 'refuses a resource that owns no object' do
    delegate = DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name, uri: 'https://iiif.example/t.jpg')
    expect { described_class.call(check: check(key: delegate.noid)) }
      .to raise_error(Exceptions::FixityCheckError) { |e| expect(e.code).to eq(:object_missing) }
  end
end
