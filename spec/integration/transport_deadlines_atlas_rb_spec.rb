# frozen_string_literal: true

require 'rails_helper'

# atlas_rb's request deadline and retry policy (1.16.0), proven against the
# live server.
#
# What went wrong without them: nothing in the gem set a timeout, so
# Net::HTTP's 60s defaults applied — and because the pooled adapter kept
# max_retries = 1, Net::HTTP replayed an idempotent GET after a read timeout,
# so one hung GET held a request thread for 120 seconds. A consumer that fans
# out four reads per page parks four sockets from a sixteen-socket pool for
# that whole time, which is how one degraded backend becomes a front-end
# outage. A host cannot fix that from outside: it can rescue what the gem
# raises, but it cannot put a deadline on a socket the gem owns.
#
# Three things need pinning here, and the third is the trap. A response Atlas
# actually sent must never be retried, because the maintenance 503 carries a
# Retry-After measured in minutes — retrying it in band would hammer the
# window and swallow the ReadOnlyModeError the caller needs.
RSpec.describe 'Transport deadlines and retries via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { ATLAS_RB_SERVER_ADMIN_NUID }

  # Config is read when a connection is first built, and the connection is
  # cached process-wide, so any example that changes a slot has to drop the
  # cache or it asserts against a connection an earlier example built. The
  # harness's after-hook resets both the slots and the cache.
  def rebuild_connections
    AtlasRb::Transport.reset_connections!
  end

  # A port nothing is listening on: bind one, read the number, hand it back.
  def closed_port
    server = TCPServer.new('127.0.0.1', 0)
    port   = server.addr[1]
    server.close
    port
  end

  # Point the gem at `url` for the duration of the block, with a fresh
  # connection either side so neither state leaks.
  def with_atlas_url(url)
    saved = ENV.fetch('ATLAS_URL', nil)
    ENV['ATLAS_URL'] = url
    rebuild_connections
    yield
  ensure
    ENV['ATLAS_URL'] = saved
    rebuild_connections
  end

  # One event per outbound HTTP request. The retry middleware sits outside the
  # instrumentation, so this counts attempts rather than logical calls.
  def count_attempts
    attempts = 0
    subscriber = ActiveSupport::Notifications.subscribe('request.atlas_rb') { attempts += 1 }
    yield
    attempts
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  describe 'the deadline on each connection shape' do
    it 'ships a default open and read timeout on the JSON connection' do
      options = AtlasRb::Work.connection({}, admin_nuid).connection.options

      expect(options.open_timeout).to eq(AtlasRb::Transport::DEFAULT_OPEN_TIMEOUT)
      expect(options.timeout).to eq(AtlasRb::Transport::DEFAULT_READ_TIMEOUT)
    end

    # A multi-gigabyte upload legitimately outlives any page-sized budget, and
    # those calls run in jobs rather than on a request thread.
    it 'leaves the multipart connection uncapped on read' do
      options = AtlasRb::Blob.multipart(admin_nuid).connection.options

      expect(options.open_timeout).to eq(AtlasRb::Transport::DEFAULT_OPEN_TIMEOUT)
      expect(options.timeout).to be_nil
    end

    it 'honours a host-configured budget' do
      AtlasRb.config.read_timeout = 3
      AtlasRb.config.open_timeout = 1
      rebuild_connections

      options = AtlasRb::Work.connection({}, admin_nuid).connection.options

      expect(options.open_timeout).to eq(1)
      expect(options.timeout).to eq(3)
    end

    # `false` and `nil` have to mean different things, or a host cannot opt out
    # without knowing the default it is opting out of.
    it 'reads false as no deadline and nil as the default' do
      AtlasRb.config.read_timeout = false
      rebuild_connections
      expect(AtlasRb::Work.connection({}, admin_nuid).connection.options.timeout).to be_nil

      AtlasRb.config.read_timeout = nil
      rebuild_connections
      expect(AtlasRb::Work.connection({}, admin_nuid).connection.options.timeout)
        .to eq(AtlasRb::Transport::DEFAULT_READ_TIMEOUT)
    end

    # The escape hatch for a call that knows better — a bulk export, a large
    # subtree page. The block the transport forwards runs last, so it wins.
    it 'lets one call override the budget on its own request' do
      default = AtlasRb::Work.connection({}, admin_nuid).get('/works/')
      expect(default.env.request.timeout).to eq(AtlasRb::Transport::DEFAULT_READ_TIMEOUT)

      overridden = AtlasRb::Work.connection({}, admin_nuid)
                                .get('/works/') { |req| req.options.timeout = 120 }
      expect(overridden.env.request.timeout).to eq(120)
    end
  end

  describe 'the retry policy' do
    it 'retries a refused connection up to three attempts, then raises' do
      attempts = nil

      with_atlas_url("http://127.0.0.1:#{closed_port}") do
        attempts = count_attempts do
          expect { AtlasRb::Work.find('anything', nuid: admin_nuid) }
            .to raise_error(Faraday::ConnectionFailed)
        end
      end

      expect(attempts).to eq(3)
    end

    it 'makes one attempt when a host switches retrying off' do
      AtlasRb.config.read_retries = 0
      attempts = nil

      with_atlas_url("http://127.0.0.1:#{closed_port}") do
        attempts = count_attempts do
          expect { AtlasRb::Work.find('anything', nuid: admin_nuid) }
            .to raise_error(Faraday::ConnectionFailed)
        end
      end

      expect(attempts).to eq(1)
    end

    # A write that may have landed is the call site's decision, not the
    # transport's — Atlas's DELETE purges an OCFL object and its PATCH/PUT
    # writes carry optimistic-lock semantics.
    it 'never replays a write' do
      attempts = nil

      with_atlas_url("http://127.0.0.1:#{closed_port}") do
        attempts = count_attempts do
          expect { AtlasRb::Community.create(nil, nuid: admin_nuid) }
            .to raise_error(Faraday::ConnectionFailed)
        end
      end

      expect(attempts).to eq(1)
    end

    # The trap. Only an exception retries; a response Atlas sent is final. If
    # statuses were retriable, a maintenance window would be hit three times
    # per call site and its Retry-After — minutes, not milliseconds — ignored.
    it 'never retries a response Atlas actually sent' do
      attempts = count_attempts do
        expect(AtlasRb::Work.find('nosuchnoid', nuid: admin_nuid)).to be_nil
      end

      expect(attempts).to eq(1)
    end

    # Net::HTTP replays an idempotent request itself, with no backoff, no
    # jitter and no instrumentation. Leaving that on under the middleware would
    # multiply the attempts and double every timeout wait.
    it 'leaves the replay to the middleware, not to Net::HTTP' do
      http = Net::HTTP::Persistent.new
      AtlasRb::Transport.configure_persistent(http)

      expect(http.max_retries).to eq(0)
    end
  end

  # Faraday runs on_complete innermost-first, so the handler registered
  # earliest runs last. Retrying has to wrap everything, the generic read guard
  # has to run after the typed translators, and the redirect has to be resolved
  # before any of them look at a status. Reorder these and a maintenance 503
  # quietly becomes a generic ResourceError.
  describe 'the middleware stack' do
    it 'wraps the typed translators in the retry and the read guard' do
      handlers = AtlasRb::Work.connection({}, admin_nuid).connection.builder.handlers

      expect(handlers.first).to eq(Faraday::Retry::Middleware)
      expect(handlers.index(AtlasRb::Middleware::RaiseOnReadError))
        .to be < handlers.index(AtlasRb::Middleware::RaiseOnReadOnlyMode)
      expect(handlers.last).to eq(Faraday::FollowRedirects::Middleware)
    end
  end
end
