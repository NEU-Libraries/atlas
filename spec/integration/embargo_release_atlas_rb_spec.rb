# frozen_string_literal: true

require 'rails_helper'

# AtlasRb::System.release_embargoes through the live server. The binding is the
# only thing Cerberus's nightly job calls, so this proves the path it relies on:
# the system token, the `since` query string and the `released` unwrap.
RSpec.describe 'Embargo release via atlas_rb', :atlas_rb_server do
  # See maintenance_atlas_rb_spec.rb: client and server share one credentials
  # object here, so one secret on both sides authenticates as :system.
  let(:system_secret) { 'test-system-token' }

  let!(:system_user) do
    User.find_by(nuid: AtlasRb::System::NUID) ||
      User.create!(email: 'system@example.invalid', password: SecureRandom.hex(16),
                   nuid: AtlasRb::System::NUID, name: 'User, System', role: :system)
  end

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  before do
    allow(Rails.application.credentials).to receive(:system_token).and_return(system_secret)
    allow(Rails.application.credentials).to receive(:atlas_system_token).and_return(system_secret)
  end

  after do
    MaintenanceMode.delete_all
    MaintenanceMode::Cache.reset
  end

  def lapsed_work(days_ago)
    work = WorkCreator.call(parent_id: collection.noid)
    work.permissions = work.permissions.merge(embargo: days_ago.days.ago.to_date.iso8601)
    Atlas.persister.save(resource: work)
  end

  it 'records a lapsed embargo as the system principal, then writes nothing on a repeat' do
    work = lapsed_work(2)

    expect(AtlasRb::System.release_embargoes).to eq([work.noid])
    expect(AtlasRb::System.release_embargoes).to eq([])

    row = AuditEvent.for_resource(work.id).sole
    expect(row).to have_attributes(action: 'release_embargo', actor_nuid: AtlasRb::System::NUID,
                                   event_source: 'job')
  end

  it 'widens the window with since' do
    old = lapsed_work(20)

    expect(AtlasRb::System.release_embargoes).to eq([])
    expect(AtlasRb::System.release_embargoes(since: 30.days.ago.to_date)).to eq([old.noid])
  end

  it 'raises a typed error during a maintenance window' do
    lapsed_work(2)
    AtlasRb::Maintenance.write(read_only: true, source: 'operator')

    expect { AtlasRb::System.release_embargoes }.to raise_error(AtlasRb::ReadOnlyModeError)
  end
end
