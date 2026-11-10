# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExampleWatchdog do
  before do
    stub_const('ExampleWatchdog::LIMIT', 1)
    stub_const('ExampleWatchdog::GRACE', 1)
    stub_const('ExampleWatchdog::SLOW_QUERY', 0)
  end

  let(:example) { instance_double(RSpec::Core::Example, location: './spec/stuck_spec.rb:1', full_description: 'a stuck example') }

  # A thread stuck in a query on a connection of its own, as an example's is.
  def stuck_thread(backend_box)
    thread = Thread.new do
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      session = PG.connect(host: config[:host], port: config[:port], dbname: config[:database],
                           user: config[:username], password: config[:password])
      backend_box << session.backend_pid
      session.exec('SELECT pg_sleep(30)')
    ensure
      session&.close
    end
    thread.report_on_exception = false
    thread
  end

  def wait_for(box)
    50.times { box.empty? ? sleep(0.1) : break }
    box.first
  end

  it 'writes the stuck query into its report and cancels it' do
    box = []
    stuck = stuck_thread(box)
    fired = []
    reports = Rails.root.glob('tmp/spec-watchdog-*.log')
    described_class.watch(example, stuck, wait_for(box), fired)

    expect(fired).to eq([true])
    expect { stuck.join(5) }.to raise_error(PG::QueryCanceled)
    report = (Rails.root.glob('tmp/spec-watchdog-*.log') - reports).sole
    expect(report.read).to include('./spec/stuck_spec.rb:1', 'pg_sleep', 'example thread', 'most dead rows')
  ensure
    stuck&.kill
    FileUtils.rm_f(report) if report
  end

  it 'raises into an example that carries on after its query is cancelled' do
    looping = Thread.new { loop { sleep 0.05 } }.tap { |t| t.report_on_exception = false }
    reports = Rails.root.glob('tmp/spec-watchdog-*.log')
    described_class.watch(example, looping, nil, [])

    expect { looping.join(5) }.to raise_error(ExampleWatchdog::Timeout, /ran past 1s/)
  ensure
    looping&.kill
    (Rails.root.glob('tmp/spec-watchdog-*.log') - reports).each { FileUtils.rm_f(it) }
  end
end
