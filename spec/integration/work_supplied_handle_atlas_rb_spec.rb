# frozen_string_literal: true

require 'rails_helper'

# atlas_rb — AtlasRb::Work.create(handle:) is how the v1 migration keeps a
# migrated Work's registered handle. Exercised through the live server so the
# admin gate, the typed errors, the idempotent replay and the /complete that
# must mint nothing are proven against the real endpoint. See docs/handles.md.
RSpec.describe 'Work create with a supplied handle via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { ATLAS_RB_SERVER_ADMIN_NUID }
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let!(:staff) do
    User.create!(email: 'handle-staff@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000783', name: 'Doe, Staff', role: :standard,
                 groups: [Permissions::STAFF_EDIT_GROUP])
  end

  # A configured handle server, so a mint would happen if HandleMinter chose
  # to. The Puma server is a thread of this process, so the stub reaches it.
  let(:handle_client) do
    instance_double(HandleClient, configured?: true).tap do |double|
      allow(double).to receive(:mint) { |suffix, **| "2047/#{suffix}" }
    end
  end

  before { allow(HandleClient).to receive(:new).and_return(handle_client) }

  it 'records the handle, and /complete then mints nothing and writes one identifier' do
    created = AtlasRb::Work.create(collection.noid, handle: '2047/d20001234', nuid: admin_nuid)
    expect(created['handle']).to eq('2047/d20001234')

    with_env('CERBERUS_PUBLIC_BASE' => 'https://repository.example.edu') do
      AtlasRb::Work.complete(created['id'], nuid: admin_nuid)
    end

    work = Work.find(created['id'])
    identifiers = Nokogiri::XML(work.mods_xml)
                          .xpath("/mods:mods/mods:identifier[@type='hdl']", NEU::MODS::NAMESPACE)
    expect(handle_client).not_to have_received(:mint)
    expect(work).to have_attributes(handle: '2047/d20001234', handle_source: 'supplied', in_progress: false)
    expect(identifiers.map(&:text)).to eq(['https://hdl.handle.net/2047/d20001234'])
  end

  # The control for the example above: without it, a stub or an ENV value that
  # never reached the server would let "mints nothing" pass for the wrong reason.
  it 'mints for a Work created without a handle, under the same setup' do
    created = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)

    with_env('CERBERUS_PUBLIC_BASE' => 'https://repository.example.edu') do
      AtlasRb::Work.complete(created['id'], nuid: admin_nuid)
    end

    expect(handle_client).to have_received(:mint).once
    expect(Work.find(created['id'])).to have_attributes(handle: "2047/#{created['id']}", handle_source: 'minted')
  end

  it 'raises ResourceError 409 for a handle another Work holds' do
    AtlasRb::Work.create(collection.noid, handle: '2047/d20001234', nuid: admin_nuid)

    expect { AtlasRb::Work.create(collection.noid, handle: '2047/d20001234', nuid: admin_nuid) }
      .to raise_error(AtlasRb::ResourceError) { |error| expect(error.status).to eq(409) }
    expect(collection.children.grep(Work).size).to eq(1)
  end

  it 'raises ResourceError 422 for a value that is not a handle' do
    expect { AtlasRb::Work.create(collection.noid, handle: 'd20001234', nuid: admin_nuid) }
      .to raise_error(AtlasRb::ResourceError) { |error| expect(error.status).to eq(422) }
  end

  # The caller can create Works in this Collection, so the refusal is the
  # handle gate's alone.
  it 'raises ForbiddenError for a caller below the admin tiers, and creates nothing' do
    expect { AtlasRb::Work.create(collection.noid, handle: '2047/d20001234', nuid: staff.nuid) }
      .to raise_error(AtlasRb::ForbiddenError) { |error| expect(error.action).to eq('supply_handle') }
    expect(collection.children.grep(Work)).to be_empty
  end

  it 'returns the original Work, unchanged, on a replay of the same idempotency key' do
    key   = SecureRandom.uuid
    first = AtlasRb::Work.create(collection.noid, handle: '2047/d20001234', nuid: admin_nuid, idempotency_key: key)

    again = AtlasRb::Work.create(collection.noid, handle: '2047/d20009999', nuid: admin_nuid, idempotency_key: key)

    expect(again['id']).to eq(first['id'])
    expect(again['handle']).to eq('2047/d20001234')
    expect(collection.children.grep(Work).size).to eq(1)
  end
end
