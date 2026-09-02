# frozen_string_literal: true

require 'rails_helper'

# atlas_rb keeps one pooled Faraday connection per shape and base URL, so a run
# of Atlas calls reuses its sockets instead of opening one per request. Over
# plain HTTP that saves a TCP handshake; under TLS it saves a TLS handshake as
# well, which is where the cost actually lives.
#
# Latency is not the assertion here. A latency improvement can come from
# anywhere, but a drop in the number of TCP connects cannot, so these examples
# count connects: `TCPSocket.open` is the one call `Net::HTTP` makes to dial
# out, and Puma's own listener does not go through it, so counting calls aimed
# at the live server's port isolates client-side handshakes exactly.
#
# The rest of the file guards what pooling puts at risk — per-request state
# that used to be baked into a per-request connection, streaming in both
# directions, and cross-example isolation.
RSpec.describe 'atlas_rb connection reuse', :atlas_rb_server do
  let(:admin_nuid) { '000000004' }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:fixture)    { Rails.root.join('spec/fixtures/files/example.bin').to_s }

  # Count outbound TCP connects to the live Atlas server while the block runs.
  def connects_to_atlas
    port  = URI.parse(ENV.fetch('ATLAS_URL')).port
    count = 0
    mutex = Mutex.new
    original = TCPSocket.method(:open)
    TCPSocket.singleton_class.send(:define_method, :open) do |host, remote_port = nil, *rest, &blk|
      mutex.synchronize { count += 1 } if remote_port.to_i == port
      original.call(host, remote_port, *rest, &blk)
    end
    yield
    count
  ensure
    TCPSocket.singleton_class.send(:define_method, :open, original)
  end

  # Each example starts from a cold pool, so a count is about this example's
  # own traffic rather than whatever ran before it.
  before { AtlasRb::Transport.reset_connections! }

  it 'opens one socket for a run of sequential reads' do
    noid = work.noid

    connects = connects_to_atlas do
      5.times { AtlasRb::Work.find(noid, nuid: admin_nuid) }
    end

    expect(connects).to eq(1)
  end

  it 'reuses the pool across short-lived threads, which a thread-local connection could not' do
    noid = work.noid
    AtlasRb::Work.find(noid, nuid: admin_nuid) # fill the pool with one socket

    # Cerberus fans its page reads out on threads that die with the request. A
    # connection memoised per thread would be discarded with them; a shared
    # pool takes the socket back and hands it to the next thread.
    connects = connects_to_atlas do
      2.times do
        [Thread.new { AtlasRb::Work.find(noid, nuid: admin_nuid) }].each(&:join)
      end
    end

    expect(connects).to be_zero
  end

  it 'grows to the concurrent fan-out and then stops opening sockets' do
    noid = work.noid
    fan_out = -> { 4.times.map { Thread.new { AtlasRb::Work.find(noid, nuid: admin_nuid) } }.each(&:join) }

    first  = connects_to_atlas { fan_out.call }
    second = connects_to_atlas { fan_out.call }

    expect(first).to be <= 4
    expect(second).to be_zero
  end

  describe 'per-request state, which the shared connection cannot carry' do
    it 'signs a fresh assertion per request rather than reusing the first' do
      # The assertion lives 30 seconds. Baked into a connection that outlives
      # the request it would eventually go out expired, so it has to be built
      # per request even though the connection is not.
      seen = []
      subscription = ActiveSupport::Notifications.subscribe('request.atlas_rb') do |*args|
        seen << ActiveSupport::Notifications::Event.new(*args).payload.request_headers['Authorization']
      end

      2.times { AtlasRb::Work.find(work.noid, nuid: admin_nuid) }

      expect(seen.size).to eq(2)
      expect(seen.uniq.size).to eq(2)
      expect(seen).to all(match(/\ABearer /))
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it 'sends a different acting principal on each request over the same socket' do
      other = User.create!(email: 'reuse-other@example.invalid', password: SecureRandom.hex(16),
                           nuid: '000000077', name: 'Other, Person', role: :admin)
      noid = work.noid

      connects = connects_to_atlas do
        subjects = capture_assertion_subjects do
          AtlasRb::Work.find(noid, nuid: admin_nuid)
          AtlasRb::Work.find(noid, nuid: other.nuid)
        end
        expect(subjects).to eq([admin_nuid, other.nuid])
      end

      expect(connects).to eq(1)
    end

    it 'carries query params on the request, not on the connection' do
      3.times { WorkCreator.call(parent_id: collection.noid) }

      connects = connects_to_atlas do
        expect(AtlasRb::Work.list(in_progress: true, nuid: admin_nuid)['works'].size).to eq(3)
        expect(AtlasRb::Work.list(in_progress: false, nuid: admin_nuid)['works']).to be_empty
      end

      expect(connects).to eq(1)
    end

    it 'replays an Idempotency-Key to the same resource over a reused socket' do
      key = SecureRandom.uuid

      first  = AtlasRb::Work.create(collection.noid, nuid: admin_nuid, idempotency_key: key)
      second = AtlasRb::Work.create(collection.noid, nuid: admin_nuid, idempotency_key: key)

      expect(second['id']).to eq(first['id'])
    end
  end

  describe 'streaming' do
    it 'streams a download and forwards a Range header over a pooled socket' do
      blob = AtlasRb::Blob.create(work.noid, fixture, 'example.bin', nuid: admin_nuid)

      buffer = String.new(encoding: Encoding::ASCII_8BIT)
      res = AtlasRb::Blob.content(blob['id'], range: 'bytes=0-9', nuid: admin_nuid) do |chunk|
        buffer << chunk
      end

      expect(res[:status]).to eq(206)
      expect(buffer).to eq(File.binread(fixture)[0..9])

      # The socket a streamed response was read from goes back to the pool
      # usable, rather than being left half-read.
      expect(AtlasRb::Work.find(work.noid, nuid: admin_nuid)['id']).to eq(work.noid)
    end

    it 'hands the upload to the adapter as a stream, not as a String body' do
      # faraday-multipart wraps the part in a streaming CompositeReadIO, which
      # the adapter sends via request.body_stream. A String body here would
      # mean whole files read into memory — on a TB-scale migration a far worse
      # regression than the latency this pooling recovers. RSS is not the
      # assertion, because the live server shares this process and its own
      # buffering would be counted as the client's.
      bodies = []
      subscription = ActiveSupport::Notifications.subscribe('request.atlas_rb') do |*args|
        bodies << ActiveSupport::Notifications::Event.new(*args).payload.request_body
      end

      created = AtlasRb::Blob.create(work.noid, fixture, 'example.bin', nuid: admin_nuid)

      expect(created['size']).to eq(File.size(fixture))
      upload = bodies.compact.find { |b| b.respond_to?(:read) }
      expect(upload).not_to be_nil
      expect(upload).not_to be_a(String)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
  end

  describe '.reset_connections!' do
    it 'closes the pooled sockets and rebuilds on the next call' do
      noid = work.noid
      AtlasRb::Work.find(noid, nuid: admin_nuid)

      AtlasRb::Transport.reset_connections!

      connects = connects_to_atlas do
        expect(AtlasRb::Work.find(noid, nuid: admin_nuid)['id']).to eq(noid)
      end

      expect(connects).to eq(1)
    end
  end

  # The `sub` of each assertion sent while the block runs — the acting
  # principal Atlas will resolve identity from.
  def capture_assertion_subjects
    subjects = []
    subscription = ActiveSupport::Notifications.subscribe('request.atlas_rb') do |*args|
      token = ActiveSupport::Notifications::Event.new(*args)
                                                 .payload.request_headers['Authorization']
                                                 .sub(/\ABearer /, '')
      subjects << JWT.decode(token, nil, false).first['sub']
    end
    yield
    subjects
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end
end
