# frozen_string_literal: true

require 'rails_helper'

# bin/fixity-entrypoint.sh with a stub in place of the sweep, waking five times
# a second, so a test can watch several wakes inside one window.
RSpec.describe 'bin/fixity-entrypoint.sh' do
  let(:dir)    { Pathname(Dir.mktmpdir('fixity-entrypoint')) }
  let(:calls)  { dir.join('calls') }
  let(:marker) { dir.join('fixity-window') }
  let(:today)  { Time.now.utc.to_date }

  before do
    stub = dir.join('sweep')
    stub.write(<<~SH)
      #!/bin/sh
      echo "$*" >> "#{calls}"
      exit "${STUB_EXIT:-0}"
    SH
    stub.chmod(0o755)
  end

  after { FileUtils.rm_rf(dir) }

  # Start 0 and end 24 put every hour inside the window.
  def run_entrypoint(env = {}, seconds: 1.2)
    env = { 'FIXITY_WINDOW_START' => '0', 'FIXITY_WINDOW_END' => '24', 'FIXITY_INTERVAL' => '0.2',
            'FIXITY_SWEEP' => dir.join('sweep').to_s, 'TMPDIR' => dir.to_s, 'ATLAS_URL' => 'http://atlas.invalid/',
            'OCFL_ROOTS' => dir.join('no-root').to_s, 'OCFL_EXTRA_ROOTS' => nil }.merge(env)
    pid = Process.spawn(env, Rails.root.join('bin/fixity-entrypoint.sh').to_s,
                        out: dir.join('log').to_s, err: %i[child out], pgroup: true)
    sleep seconds
    Process.kill('TERM', -pid)
    Process.wait(pid)
  end

  def sweeps
    calls.exist? ? calls.readlines(chomp: true) : []
  end

  it 'runs one sweep per window once a sweep finishes' do
    run_entrypoint

    expect(sweeps.size).to eq(1)
    expect(marker.read.strip).to eq(today.iso8601)
    expect(dir.join('log').read).to include("window opened #{today.iso8601} is done")
  end

  it 'retries on the next wake when the sweep exits non-zero' do
    run_entrypoint({ 'STUB_EXIT' => '1' })

    expect(sweeps.size).to be > 1
    expect(marker).not_to exist
  end

  it 'sweeps again when the last finished sweep was in an earlier window' do
    marker.write("#{(today - 1).iso8601}\n")
    run_entrypoint

    expect(sweeps.size).to eq(1)
    expect(marker.read.strip).to eq(today.iso8601)
  end

  # A window that crosses midnight belongs to the date it opened on, so its
  # small hours do not count as a new night.
  it 'dates a window that crosses midnight by the day it opened' do
    hour = Time.now.utc.hour
    run_entrypoint({ 'FIXITY_WINDOW_START' => '23', 'FIXITY_WINDOW_END' => ((hour + 1) % 24).to_s })

    expect(marker.read.strip).to eq((hour < 23 ? today - 1 : today).iso8601)
  end

  it 'passes the budget and the cycle through to the sweep' do
    run_entrypoint({ 'FIXITY_BUDGET' => '500GB', 'FIXITY_CYCLE' => '90d' })

    expect(sweeps.first).to include('--budget 500GB', '--cycle 90d', '--report-to http://atlas.invalid/')
  end
end
