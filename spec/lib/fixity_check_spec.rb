# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FixityCheck do
  let(:body) do
    { 'object' => 'urn:neu-drs:pvmcxgb', 'checked_at' => '2026-10-27T03:12:09.456Z', 'version' => 'v3',
      'algorithm' => 'sha512', 'files' => 4, 'result' => 'pass', 'findings' => [],
      'checker' => 'ocfl-fixity-sweep 1.0' }
  end

  def check(overrides = {})
    described_class.new(body.merge(overrides), recorded_by: '000000000')
  end

  def rejection(overrides)
    check(overrides)
    nil
  rescue Exceptions::FixityCheckError => e
    e.code
  end

  it 'reads the object key and the canonical fields' do
    expect(check).to have_attributes(key: 'pvmcxgb', version: 'v3', result: 'pass', checker: 'ocfl-fixity-sweep 1.0')
  end

  # The line keeps whole seconds, so the row caching it must too.
  it 'truncates checked_at to whole seconds in UTC' do
    expect(check.checked_at).to eq(Time.utc(2026, 10, 27, 3, 12, 9))
    expect(check.to_h[:checked_at]).to eq('2026-10-27T03:12:09Z')
  end

  # A retried post must give the identical line, or the log records it twice.
  it 'gives one log line for the same body, whatever order its keys arrive in' do
    shuffled = described_class.new(body.to_a.reverse.to_h, recorded_by: '000000000')
    expect(shuffled.to_log_line).to eq(check.to_log_line)
    expect(JSON.parse(check.to_log_line).keys)
      .to eq(%w[object checked_at version algorithm files result findings checker recorded_by])
  end

  it 'keeps only the known finding keys' do
    finding = { 'code' => 'fixity_mismatch', 'path' => 'v1/content/a.tif', 'extra' => 'x' }
    expect(check('result' => 'fail', 'findings' => [finding]).to_h[:findings])
      .to eq([{ 'code' => 'fixity_mismatch', 'path' => 'v1/content/a.tif' }])
  end

  it 'refuses an object that is not an Atlas inventory id' do
    expect(rejection('object' => 'pvmcxgb')).to eq(:invalid_object)
    expect(rejection('object' => 'urn:neu-drs:../etc')).to eq(:invalid_object)
  end

  it 'refuses a checked_at that is not a timestamp, or is well in the future' do
    expect(rejection('checked_at' => 'yesterday')).to eq(:invalid_checked_at)
    expect(rejection('checked_at' => 1.hour.from_now.iso8601)).to eq(:invalid_checked_at)
    expect(rejection('checked_at' => 1.minute.from_now.iso8601)).to be_nil
  end

  it 'refuses a version, algorithm, file count, result or checker out of shape' do
    expect(rejection('version' => '3')).to eq(:invalid_version)
    expect(rejection('algorithm' => 'crc32')).to eq(:invalid_algorithm)
    expect(rejection('files' => -1)).to eq(:invalid_files)
    expect(rejection('files' => '4')).to eq(:invalid_files)
    expect(rejection('result' => 'ok')).to eq(:invalid_result)
    expect(rejection('checker' => '')).to eq(:invalid_checker)
    expect(rejection('checker' => 'x' * 65)).to eq(:invalid_checker)
  end

  it 'refuses a fail with no findings, and a finding with no code' do
    expect(rejection('result' => 'fail')).to eq(:invalid_findings)
    expect(rejection('findings' => [{ 'path' => 'a' }])).to eq(:invalid_findings)
    expect(rejection('findings' => 'none')).to eq(:invalid_findings)
  end
end
