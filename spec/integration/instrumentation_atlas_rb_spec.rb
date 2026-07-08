# frozen_string_literal: true

require 'rails_helper'

# atlas_rb brackets every outbound Atlas request in an ActiveSupport::Notifications
# event so a host (Cerberus) can count/time round-trips — an N+1-over-HTTP smell
# detector — without reaching into gem internals. Two properties are exercised
# against the live server: (1) an event fires per request carrying the HTTP
# method / URL / duration, and (2) a call that redirects internally (the
# `/resources/:noid` NOID resolver) folds into ONE event, because the middleware
# sits above follow_redirects rather than being double-counted per hop.
RSpec.describe 'atlas_rb request instrumentation', :atlas_rb_server do
  let(:admin_nuid) { '000000004' }

  # The event name is the consumer contract — a subscriber names this exact
  # string — so the spec pins the literal, not a gem-internal constant.
  EVENT_NAME = 'request.atlas_rb'

  # Collect the AS::Notifications events emitted while the block runs. The
  # subscription is example-scoped and torn down in ensure so it can't leak
  # into a later example.
  def atlas_events
    events = []
    subscription = ActiveSupport::Notifications.subscribe(EVENT_NAME) do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  it 'emits an event per request carrying the HTTP method, URL, and duration' do
    parent = CommunityCreator.call

    events = atlas_events do
      AtlasRb::Community.create(parent.noid, nuid: admin_nuid)
    end

    expect(events).not_to be_empty
    post = events.find { |e| e.payload.method == :post }
    expect(post).not_to be_nil
    # Payload is the Faraday env — a subscriber reads method/url off it directly.
    expect(post.payload.url.path).to include('communities')
    expect(post.duration).to be > 0
  end

  it 'folds an internally-redirecting call (/resources/:noid) into a single event' do
    community = CommunityCreator.call

    events = atlas_events do
      # GET /resources/:noid 302-redirects to /communities/:valkyrie_id. With the
      # instrumentation middleware above follow_redirects, the hop is bracketed
      # inside the one logical call — one event, not one-per-hop.
      AtlasRb::Resource.find(community.noid, nuid: admin_nuid)
    end

    expect(events.size).to eq(1)
    expect(events.first.payload.method).to eq(:get)
  end
end
