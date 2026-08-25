# frozen_string_literal: true

require 'rails_helper'

# End-to-end proof of the maintenance window through the live server — the one
# layer that can prove it, because the contract spans two repos: Atlas's 503 +
# `read_only_mode` envelope and atlas_rb's middleware that turns it into a typed
# error.
#
# The failure this guards against is a silent one. Before atlas_rb 1.13.0 a 503
# reached neither RaiseOnStaleResource (409-only) nor RaiseOnResourceError
# (403/422-only), and Atlas's refusal envelope carries no `work` / `collection`
# key — so the binding unwrapped nil and returned it. The write no-opped and the
# caller reported success. A unit spec on either side passes while that hole is
# open; only the round trip closes it.
RSpec.describe 'Maintenance window via atlas_rb', :atlas_rb_server do
  # atlas_rb's system_connection reads its bearer from
  # credentials.atlas_system_token; the server validates it against
  # credentials.system_token. Client and server share one credentials object in
  # this process, so pointing both at the same secret authenticates as :system.
  let(:system_secret) { 'test-system-token' }

  let!(:system_user) do
    User.find_by(nuid: AtlasRb::System::NUID) ||
      User.create!(email: 'system@example.invalid', password: SecureRandom.hex(16),
                   nuid: AtlasRb::System::NUID, name: 'User, System', role: :system)
  end

  let!(:community) { CommunityCreator.call }

  before do
    allow(Rails.application.credentials).to receive(:system_token).and_return(system_secret)
    allow(Rails.application.credentials).to receive(:atlas_system_token).and_return(system_secret)
  end

  after do
    MaintenanceMode.delete_all
    MaintenanceMode::Cache.reset
  end

  it 'refuses a write with a typed error rather than a silent nil' do
    AtlasRb::Maintenance.write(read_only: true, source: 'operator', message: 'Back at 10:00')

    expect { AtlasRb::Collection.create(community.noid, nuid: ATLAS_RB_SERVER_ADMIN_NUID) }
      .to raise_error(AtlasRb::ReadOnlyModeError) do |error|
        expect(error.code).to eq('read_only_mode')
        expect(error.retry_after).to eq(900)
      end
  end

  # The read floor has to answer while the window is open: a client that could
  # not see the flag could not honour it.
  it 'still answers the flag while the window is open' do
    AtlasRb::Maintenance.write(read_only: true, source: 'deploy', message: 'Migrating')

    window = AtlasRb::Maintenance.read(nuid: ATLAS_RB_SERVER_ADMIN_NUID)

    expect(window['read_only']).to be(true)
    expect(window['source']).to eq('deploy')
    expect(window['message']).to eq('Migrating')
    expect(window['since']).to be_present
  end

  it 'keeps serving reads of ordinary resources' do
    AtlasRb::Maintenance.write(read_only: true, source: 'operator')

    expect(AtlasRb::Community.find(community.noid, nuid: ATLAS_RB_SERVER_ADMIN_NUID)['id'])
      .to eq(community.noid)
  end

  it 'lets writes through again once the window closes' do
    AtlasRb::Maintenance.write(read_only: true, source: 'operator')
    closed = AtlasRb::Maintenance.write(read_only: false, source: 'operator')

    expect(closed['read_only']).to be(false)
    expect(AtlasRb::Collection.create(community.noid, nuid: ATLAS_RB_SERVER_ADMIN_NUID)['id'])
      .to be_present
  end

  # Atlas refuses this by answering 200 with the UNCHANGED state, not an error,
  # so a caller must read read_only off the return value. Getting this wrong
  # means a finishing deploy silently reopens the repository mid-migration.
  it 'does not let a finishing deploy close an operator-opened window' do
    AtlasRb::Maintenance.write(read_only: true, source: 'operator')

    result = AtlasRb::Maintenance.write(read_only: false, source: 'deploy')

    expect(result['read_only']).to be(true)
    expect(result['source']).to eq('operator')
    expect(AtlasRb::Maintenance.read(nuid: ATLAS_RB_SERVER_ADMIN_NUID)['read_only']).to be(true)
  end
end
