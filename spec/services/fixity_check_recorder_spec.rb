# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FixityCheckRecorder do
  let(:adapter) { Valkyrie.config.storage_adapter }
  # Completed: an in-progress Work is indexed by POST /works/:id/complete, so
  # the owner reindex skips it.
  let(:work) do
    created = WorkCreator.call(parent_id: CollectionCreator.call(parent_id: CommunityCreator.call.noid).noid)
    created.in_progress = false
    Atlas.persister.save(resource: created)
  end

  after { Atlas.persister.wipe! }

  def check(at: '2026-10-27T03:12:09Z', result: 'pass', key: work.noid, version: 'v1')
    findings = result == 'fail' ? [{ 'code' => 'fixity_mismatch', 'path' => 'v1/content/a' }] : []
    FixityCheck.new({ 'object' => "urn:neu-drs:#{key}", 'checked_at' => at, 'version' => version,
                      'algorithm' => 'sha512', 'files' => 3, 'result' => result, 'findings' => findings,
                      'checker' => 'spec-checker 1.0' }, recorded_by: '000000000')
  end

  def solr_doc(resource, fields = 'fixity_checked_at_dtsi,fixity_result_ssi')
    Atlas.index_adapter.connection.get('select', params: { q: %(id:"#{resource.id}"), fl: fields })
         .dig('response', 'docs', 0)
  end

  def rollup
    solr_doc(work, 'work_fixity_checked_at_dtsi,work_fixity_result_ssi,work_fixity_objects_isi,' \
                   'work_fixity_never_checked_isi')
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

  describe 'the Work rollup' do
    let(:keys) { Work.find(work.noid).preserved_resources.map(&:noid) }

    def check_all(at:, result: 'pass')
      keys.each { |key| described_class.call(check: check(key: key, at: at, result: result)) }
    end

    it 'counts every object as never checked until one is' do
      described_class.call(check: check)

      expect(rollup).to eq('work_fixity_result_ssi' => 'pass', 'work_fixity_objects_isi' => keys.size,
                           'work_fixity_never_checked_isi' => keys.size - 1)
    end

    # A Work is only as verified as its least recently checked object.
    it 'carries the oldest check and the worst outcome once every object is checked' do
      check_all(at: '2026-10-20T03:00:00Z')
      described_class.call(check: check(key: keys.last, at: '2026-10-21T03:00:00Z', result: 'fail'))

      expect(rollup).to eq('work_fixity_checked_at_dtsi' => '2026-10-20T03:00:00Z', 'work_fixity_result_ssi' => 'fail',
                           'work_fixity_objects_isi' => keys.size, 'work_fixity_never_checked_isi' => 0)
    end

    # A new file is an unchecked object, so the Work is no longer fully verified.
    it 'counts a file deposited after the checks as never checked' do
      check_all(at: '2026-10-20T03:00:00Z')
      BlobCreator.call(work_id: work.noid, path: Rails.root.join('spec/fixtures/files/example.png').to_s,
                       original_filename: 'example.png')

      expect(rollup).not_to have_key('work_fixity_checked_at_dtsi')
      expect(rollup['work_fixity_never_checked_isi']).to be_positive
    end

    it "refreshes the Work's rollup when a check names one of its FileSets" do
      file_set = keys.find { |key| Resource.find(key).is_a?(FileSet) }
      described_class.call(check: check(key: file_set, result: 'fail'))

      expect(rollup['work_fixity_result_ssi']).to eq('fail')
    end
  end
end
