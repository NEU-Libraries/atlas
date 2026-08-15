# frozen_string_literal: true

require 'rails_helper'

RSpec.describe HandleMinter do
  let!(:community) { Atlas.persister.save(resource: Community.new) }
  let!(:home)      { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
  let!(:work)      { Atlas.persister.save(resource: Work.new(a_member_of: home.id)) }

  let(:public_base) { 'https://repository.example.edu' }

  # A configured client that mints without touching the network.
  let(:client) do
    instance_double(HandleClient, configured?: true).tap do |double|
      allow(double).to receive(:mint) { |suffix, **| "DRSDEV/#{suffix}" }
    end
  end

  def mint(target = work, **overrides)
    described_class.call(work: target, client: client, public_base: public_base, **overrides)
  end

  it 'records "<prefix>/<noid>" on the Work' do
    mint

    expect(Work.find(work.id).handle).to eq("DRSDEV/#{work.noid}")
  end

  it 'points the handle at the public Work page' do
    mint

    expect(client).to have_received(:mint)
      .with(work.noid, url: "https://repository.example.edu/works/#{work.noid}")
  end

  it 'tolerates a trailing slash on the configured public base' do
    described_class.call(work: work, client: client, public_base: 'https://repository.example.edu/')

    expect(client).to have_received(:mint)
      .with(work.noid, url: "https://repository.example.edu/works/#{work.noid}")
  end

  it 'mints once — a second call leaves the existing handle alone' do
    mint
    mint(Work.find(work.id))

    expect(client).to have_received(:mint).once
  end

  it 'does nothing when no handle server is configured' do
    inert = instance_double(HandleClient, configured?: false)

    described_class.call(work: work, client: inert, public_base: public_base)

    expect(Work.find(work.id).handle).to be_nil
  end

  it 'does nothing when there is no public base to point a handle at' do
    described_class.call(work: work, client: client, public_base: nil)

    expect(Work.find(work.id).handle).to be_nil
  end

  # The whole point of the service: /complete is load-bearing, so a handle
  # server that is down must leave the Work finalized and unminted, never
  # raise into the request.
  it 'swallows a handle-server failure and leaves the Work unminted' do
    failing = instance_double(HandleClient, configured?: true)
    allow(failing).to receive(:mint).and_raise(HandleClient::Error, 'connection refused')

    expect { described_class.call(work: work, client: failing, public_base: public_base) }
      .not_to raise_error
    expect(Work.find(work.id).handle).to be_nil
  end

  it 'carries the handle into the OCFL preservation envelope' do
    mint

    payload = Work.find(work.id).graph_payload
    expect(payload[:handle]).to eq("DRSDEV/#{work.noid}")
    expect(payload[:schema_version]).to eq(5)
  end
end
