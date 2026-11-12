# frozen_string_literal: true

require 'rails_helper'

# atlas_rb — legacy_pid: on the three creates, LegacyPidError, and the lookup
# on both the user and the system path, through the live server. This is how
# the v1 migration records each object's pid and how Cerberus redirects an old
# v1 URL. See docs/legacy-pids.md.
RSpec.describe 'Legacy pids via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { ATLAS_RB_SERVER_ADMIN_NUID }
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  # See maintenance_atlas_rb_spec.rb: client and server share one credentials
  # object here, so one secret on both sides authenticates as :system.
  let(:system_secret) { 'test-system-token' }
  let!(:system_user) do
    User.find_by(nuid: AtlasRb::System::NUID) ||
      User.create!(email: 'system@example.invalid', password: SecureRandom.hex(16),
                   nuid: AtlasRb::System::NUID, name: 'User, System', role: :system)
  end
  let!(:staff) do
    User.create!(email: 'pid-staff@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000784', name: 'Doe, Staff', role: :standard,
                 groups: [Permissions::STAFF_EDIT_GROUP])
  end

  before do
    allow(Rails.application.credentials).to receive(:system_token).and_return(system_secret)
    allow(Rails.application.credentials).to receive(:atlas_system_token).and_return(system_secret)
  end

  it 'records the pid on each create, and find reads it back' do
    root  = AtlasRb::Community.create(nil, legacy_pid: 'neu:1', nuid: admin_nuid)
    child = AtlasRb::Collection.create(root['id'], legacy_pid: 'neu:2', nuid: admin_nuid)
    work  = AtlasRb::Work.create(child['id'], legacy_pid: 'neu:3', nuid: admin_nuid)

    expect(AtlasRb::Community.find(root['id'], nuid: admin_nuid)['legacy_pid']).to eq('neu:1')
    expect(AtlasRb::Collection.find(child['id'], nuid: admin_nuid)['legacy_pid']).to eq('neu:2')
    expect(AtlasRb::Work.find(work['id'], nuid: admin_nuid)['legacy_pid']).to eq('neu:3')
  end

  it 'raises LegacyPidError with the holder on a taken pid, and creates nothing' do
    holder = AtlasRb::Community.create(nil, legacy_pid: 'neu:1', nuid: admin_nuid)

    expect { AtlasRb::Work.create(collection.noid, legacy_pid: 'neu:1', nuid: admin_nuid) }
      .to raise_error(AtlasRb::LegacyPidError) { |error|
        expect(error).to have_attributes(code: 'legacy_pid_taken', holder_id: holder['id'], status: 409)
      }
    expect(collection.children.grep(Work)).to be_empty
  end

  it 'raises LegacyPidError for a value that is not a v1 pid' do
    expect { AtlasRb::Collection.create(community.noid, legacy_pid: '1234', nuid: admin_nuid) }
      .to raise_error(AtlasRb::LegacyPidError) { |error|
        expect(error).to have_attributes(code: 'invalid_legacy_pid', holder_id: nil, status: 422)
      }
  end

  # The caller can create a Collection here, so the refusal is the pid gate's
  # alone.
  it 'raises ForbiddenError for a caller below admin, and creates nothing' do
    expect { AtlasRb::Collection.create(community.noid, legacy_pid: 'neu:5', nuid: staff.nuid) }
      .to raise_error(AtlasRb::ForbiddenError) { |error| expect(error.action).to eq('supply_legacy_pid') }
    expect(AtlasRb::Resource.find_by_legacy_pid('neu:5', nuid: admin_nuid)).to be_nil
  end

  it 'finds the holder on the user and the system path, and nil for an unknown pid' do
    work = AtlasRb::Work.create(collection.noid, legacy_pid: 'neu:6', nuid: admin_nuid)
    expected = { 'id' => work['id'], 'type' => 'Work', 'tombstoned' => false }

    expect(AtlasRb::Resource.find_by_legacy_pid('neu:6', nuid: admin_nuid).to_h).to eq(expected)
    expect(AtlasRb::System.find_by_legacy_pid('neu:6').to_h).to eq(expected)
    expect(AtlasRb::Resource.find_by_legacy_pid('neu:404', nuid: admin_nuid)).to be_nil
    expect(AtlasRb::System.find_by_legacy_pid('neu:404')).to be_nil
  end

  # The collection is private to staff, so the staff caller reads it and the
  # system role reads past the gate; a caller outside both gets nil.
  it 'answers nil on the user path for a holder the caller may not read' do
    AtlasRb::Collection.create(community.noid, legacy_pid: 'neu:7', nuid: admin_nuid)
    outsider = User.create!(email: 'pid-outsider@example.invalid', password: SecureRandom.hex(16),
                            nuid: '000000785', name: 'Doe, Outsider', role: :standard)

    expect(AtlasRb::Resource.find_by_legacy_pid('neu:7', nuid: outsider.nuid)).to be_nil
    expect(AtlasRb::System.find_by_legacy_pid('neu:7')['type']).to eq('Collection')
  end

  # No race example here: transactional fixtures pin one connection that the
  # Puma threads share, so a session advisory lock cannot exclude them.
  # spec/lib/legacy_pid_spec.rb races the creators on separate connections.
end
