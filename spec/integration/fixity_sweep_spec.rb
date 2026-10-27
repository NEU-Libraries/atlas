# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# bin/ocfl-fixity-sweep as the fixity service runs it: a separate process with
# no Rails, reading the storage and talking to a live Atlas over HTTP as the
# :fixity_checker fixture.
RSpec.describe 'bin/ocfl-fixity-sweep against a live Atlas', :atlas_rb_server do
  let(:fixity_token) { 'test-fixity-token' }
  let(:work) do
    created = WorkCreator.call(parent_id: CollectionCreator.call(parent_id: CommunityCreator.call.noid).noid)
    created.in_progress = false
    Atlas.persister.save(resource: created)
  end

  before do
    allow(Rails.application.credentials).to receive(:fixity_token).and_return(fixity_token)
    User.find_by(nuid: User::FIXITY_CHECKER_NUID) ||
      User.create!(email: 'fixity@example.invalid', password: SecureRandom.hex(16),
                   nuid: User::FIXITY_CHECKER_NUID, name: 'User, Fixity Checker', role: :fixity_checker)
    BlobCreator.call(work_id: work.noid, path: Rails.root.join('spec/fixtures/files/example.png').to_s,
                     original_filename: 'example.png')
  end

  def run_sweep(token: fixity_token)
    env = { 'FIXITY_TOKEN' => token, 'OCFL_ROOTS' => TestStorage.root.to_s, 'RUBYOPT' => nil,
            'BUNDLE_GEMFILE' => nil, 'BUNDLE_BIN_PATH' => nil }
    until_at = (Time.now.utc + 600).iso8601
    Open3.capture2e(env, Rails.root.join('bin/ocfl-fixity-sweep').to_s,
                    '--until', until_at, '--report-to', ENV.fetch('ATLAS_URL'))
  end

  it "checks the Work's objects and records each, so the health check reads them" do
    output, status = run_sweep

    expect(status.exitstatus).to eq(0), output
    keys = Work.find(work.noid).preserved_resources.map(&:noid)
    expect(FixityResult.where(object_key: keys).pluck(:result)).to all(eq('pass'))
    expect(FixityResult.where(object_key: keys).count).to eq(keys.size)
    expect(Valkyrie.config.storage_adapter.read_log(key: work.noid, name: 'fixity.jsonl').size).to eq(1)
    expect(WorkHealthCheck.call(noid: work.noid)[:fixity]).to include(never_checked: 0, result: 'pass')
  end

  it 'exits 1 without hashing when Atlas refuses its credential' do
    output, status = run_sweep(token: 'not-the-token')

    expect(status.exitstatus).to eq(1), output
    expect(output).to include('stopping: due list answered 401')
    expect(FixityResult.where(object_key: work.noid)).not_to exist
  end
end
