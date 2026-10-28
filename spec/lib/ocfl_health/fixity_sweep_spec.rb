# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/ocfl_health/fixity_sweep').to_s

# Stands in for Atlas: hands out the keys not yet recorded, records each post.
class FixitySweepFakeClient
  attr_reader :posted, :due_calls, :cutoffs

  def initialize(keys, status: 201)
    @keys = keys
    @status = status
    @posted = []
    @due_calls = 0
    @cutoffs = []
  end

  def due(before:, limit:)
    @due_calls += 1
    @cutoffs << before
    recorded = @posted.map { |body| body[:object].split(':').last }
    (@keys - recorded).first(limit).map { |key| { 'key' => key } }
  end

  def record(body)
    @posted << body if @status < 300
    [@status, @status < 300 ? nil : 'object_missing']
  end
end

RSpec.describe OcflHealth::FixitySweep do
  let(:work) do
    WorkCreator.call(parent_id: CollectionCreator.call(parent_id: CommunityCreator.call.noid).noid)
  end
  let!(:blob) do
    source = Rails.root.join('tmp', "sweep-#{SecureRandom.hex(4)}.png")
    FileUtils.cp(Rails.root.join('spec/fixtures/files/example.png'), source)
    BlobCreator.call(path: source.to_s, work_id: work.noid, original_filename: 'example.png')
  end
  let(:pool)   { OcflHealth::Pool.new([TestStorage.root]) }
  let(:out)    { StringIO.new }
  let(:now)    { Time.utc(2026, 10, 27, 2) }
  let(:client) { FixitySweepFakeClient.new([work.noid, blob.noid]) }

  after { Atlas.persister.wipe! }

  def sweep(client: self.client, deadline: now + 3600, budget: nil, cycle: nil, clock: -> { now })
    described_class.new(pool: pool, client: client, limits: { deadline: deadline, budget: budget, cycle: cycle },
                        clock: clock, out: out).call
  end

  it 'checks every due object and posts a pass for each' do
    summary = sweep

    expect(summary).to have_attributes(checked: 2, failed: 0, skipped: 0, stopped_by: :list)
    expect(client.posted.pluck(:object)).to eq(["urn:neu-drs:#{work.noid}", "urn:neu-drs:#{blob.noid}"])
    head = JSON.parse(pool.object_path(blob.noid).join('inventory.json').read)['head']
    expect(client.posted.last).to include(result: 'pass', version: head, algorithm: 'sha512',
                                          checked_at: '2026-10-27T02:00:00Z', checker: described_class::CHECKER)
  end

  it 'counts the files and bytes it actually hashed' do
    summary = sweep
    blob_post = client.posted.last

    expect(blob_post[:files]).to be >= 1
    expect(summary.bytes).to be >= Rails.root.join('spec/fixtures/files/example.png').size
  end

  it 'posts a fail carrying the finding when stored bytes have changed' do
    content = Dir.glob(pool.object_path(blob.noid).join('v*/content/*').to_s).first
    File.write(content, 'altered')

    summary = sweep

    expect(summary.failed).to eq(1)
    expect(client.posted.last).to include(result: 'fail')
    expect(client.posted.last[:findings].pluck(:code)).to include('fixity_mismatch')
    expect(out.string).to include("FAIL #{blob.noid}")
  end

  it 'stops at the deadline before starting another object' do
    times = [now, now + 7200]
    summary = sweep(clock: -> { times.size > 1 ? times.shift : times.first })

    expect(summary.stopped_by).to eq(:deadline)
    expect(client.posted).to be_empty
  end

  # A cutoff at the run's own start would make every object due again on the
  # next run, however recently it was checked.
  it 'asks only for objects last checked a full cycle before the run started' do
    sweep(cycle: 90 * 86_400)

    expect(client.cutoffs).to all(eq(now - (90 * 86_400)))
  end

  it 'asks for checks older than its own start when no cycle is given' do
    sweep

    expect(client.cutoffs).to all(eq(now))
  end

  it 'stops once the byte budget is spent' do
    summary = sweep(budget: 1)

    expect(summary).to have_attributes(checked: 1, stopped_by: :budget)
  end

  # An object Atlas would not record stays at the front of the due list.
  it 'passes over an object Atlas refuses rather than looping on it' do
    refusing = FixitySweepFakeClient.new([work.noid], status: 422)
    summary = sweep(client: refusing)

    expect(summary).to have_attributes(checked: 0, skipped: 1, stopped_by: :list)
    expect(refusing.due_calls).to eq(2)
  end

  it 'skips a key no root holds' do
    summary = sweep(client: FixitySweepFakeClient.new(['nosuchkey']))
    expect(summary).to have_attributes(skipped: 1, checked: 0)
  end

  it 'stops the run when Atlas refuses the checker' do
    refused = FixitySweepFakeClient.new([work.noid])
    allow(refused).to receive(:due).and_raise(OcflHealth::FixitySweep::Client::Refused, 'due list answered 503')

    expect(sweep(client: refused).stopped_by).to eq(:refused)
  end

  it 'never writes to storage' do
    before = Dir.glob(TestStorage.root.join('**', '*').to_s).index_with { |path| File.mtime(path) }
    sweep
    after = Dir.glob(TestStorage.root.join('**', '*').to_s).index_with { |path| File.mtime(path) }

    expect(after).to eq(before)
  end

  describe OcflHealth::FixitySweep::CLI do
    it 'reads HH:MM as the next time the UTC clock shows it' do
      expect(described_class.deadline('07:00', Time.utc(2026, 10, 27, 1))).to eq(Time.utc(2026, 10, 27, 7))
      expect(described_class.deadline('07:00', Time.utc(2026, 10, 27, 8))).to eq(Time.utc(2026, 10, 28, 7))
      expect(described_class.deadline('2026-10-27T05:30:00Z', Time.utc(2026, 10, 27, 1)))
        .to eq(Time.utc(2026, 10, 27, 5, 30))
    end

    it 'reads a byte size with a decimal unit' do
      expect(described_class.bytes('2TB')).to eq(2 * (10**12))
      expect(described_class.bytes('500 GB')).to eq(500 * (10**9))
      expect(described_class.bytes('1024')).to eq(1024)
      expect { described_class.bytes('lots') }.to raise_error(ArgumentError)
    end

    it 'reads a cycle in days, hours or seconds' do
      expect(described_class.seconds('90d')).to eq(90 * 86_400)
      expect(described_class.seconds('36h')).to eq(36 * 3600)
      expect(described_class.seconds('0')).to eq(0)
      expect { described_class.seconds('3m') }.to raise_error(ArgumentError)
    end

    it 'passes a 90-day cycle when none is given' do
      allow(OcflHealth::FixitySweep).to receive(:new).and_wrap_original do |original, **args|
        expect(args[:limits][:cycle]).to eq(90 * 86_400)
        original.call(**args, client: FixitySweepFakeClient.new([]))
      end
      env = { 'OCFL_ROOTS' => TestStorage.root.to_s, 'FIXITY_TOKEN' => 'x' }

      expect(described_class.run(%w[--until 07:00 --report-to http://x], env: env, out: out)).to eq(0)
    end

    it 'refuses to start without a deadline, a URL or a token' do
      env = { 'OCFL_ROOTS' => TestStorage.root.to_s }
      expect(described_class.run(%w[--report-to http://x], env: env, out: out)).to eq(64)
      expect(described_class.run(%w[--until 07:00], env: env, out: out)).to eq(64)
      expect(described_class.run(%w[--until 07:00 --report-to http://x], env: env, out: out)).to eq(64)
    end
  end
end
