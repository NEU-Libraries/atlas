# frozen_string_literal: true

require 'rails_helper'

# The round trip the Work edit screen makes: read the grade, see what is wrong,
# repair it, and read the grade again.
RSpec.describe 'Work health check via atlas_rb', :atlas_rb_server do
  let(:nuid)       { '000000004' }
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work) do
    WorkCreator.call(parent_id: collection.noid, depositor: nuid,
                     mods_xml: Rails.root.join('spec/fixtures/files/work-mods.xml').read)
  end

  # See maintenance_atlas_rb_spec.rb: client and server share one credentials
  # object here, so one secret on both sides authenticates as :system.
  let(:system_secret) { 'test-system-token' }

  before do
    User.find_by(nuid: AtlasRb::System::NUID) ||
      User.create!(email: 'system@example.invalid', password: SecureRandom.hex(16),
                   nuid: AtlasRb::System::NUID, name: 'User, System', role: :system)
    allow(Rails.application.credentials).to receive(:system_token).and_return(system_secret)
    allow(Rails.application.credentials).to receive(:atlas_system_token).and_return(system_secret)
    BlobCreator.call(work_id: work.noid, original_filename: 'a.bin',
                     path: Rails.root.join('spec/fixtures/files/example.bin').to_s)
  end

  it 'reports a missing Solr document, and green again once a reindex repairs it' do
    expect(AtlasRb::Work.health_check(work.noid, nuid: nuid).grade).to eq('green')

    Atlas.index_adapter.connection.delete_by_query(%(id:"#{work.id}"))
    Atlas.index_adapter.connection.commit
    report = AtlasRb::Work.health_check(work.noid, nuid: nuid)
    expect(report.grade).to eq('yellow')
    expect(report.findings.map(&:code)).to include('not_indexed')
    expect(report.fixity_checked).to be(false)

    AtlasRb::System.reindex(work.noid)
    expect(AtlasRb::Work.health_check(work.noid, nuid: nuid).grade).to eq('green')
  end

  # atlas_rb returns the whole body as a Mash, so the summary reaches Cerberus
  # with no client change.
  it 'carries the recorded fixity summary through the client' do
    FixityResult.advance!(key: work.noid, checked_at: Time.utc(2026, 10, 20, 2, 41, 55), result: 'pass',
                          version: 'v1', checker: 'spec')

    fixity = AtlasRb::Work.health_check(work.noid, nuid: nuid).fixity
    expect(fixity.result).to eq('pass')
    expect(fixity.last_checked_at).to be_nil
    expect(fixity.never_checked).to eq(fixity.objects - 1)
  end

  it 'returns nil for a Work that does not exist' do
    expect(AtlasRb::Work.health_check('doesnotexist', nuid: nuid)).to be_nil
  end

  it 'raises ResourceError with a 403 for a caller below the delegate tier' do
    standard = User.create!(email: 'standard-health-rb@example.invalid', password: SecureRandom.hex(16),
                            nuid: '000000058', name: 'Roe, Sam', role: :standard, groups: [])

    expect { AtlasRb::Work.health_check(work.noid, nuid: standard.nuid) }
      .to raise_error(AtlasRb::ResourceError) { |e| expect(e.status).to eq(403) }
  end
end
