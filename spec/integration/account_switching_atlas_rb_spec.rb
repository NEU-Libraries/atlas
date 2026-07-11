# frozen_string_literal: true

require 'rails_helper'

# End-to-end proof of the account-switching bindings through the live server:
# a person's staff and student logins share one NUID but each has its own email
# and Grouper set. Provision both (system path), enumerate them, choose a
# preferred, and switch between them by email — each switch resolving that
# account's stored group set (v1 parity).
RSpec.describe 'Account switching via atlas_rb', :atlas_rb_server do
  # System path (find_or_create): atlas_rb's system_connection reads its bearer
  # from credentials.atlas_system_token; the server validates it against
  # credentials.system_token. Both share one credentials object in-process, so
  # pointing them at the same secret authenticates as :system.
  let(:system_secret) { 'test-system-token' }
  let!(:system_user) do
    User.find_by(nuid: AtlasRb::System::NUID) ||
      User.create!(email: 'system@example.invalid', password: SecureRandom.hex(16),
                   nuid: AtlasRb::System::NUID, name: 'User, System', role: :system)
  end
  before do
    allow(Rails.application.credentials).to receive(:system_token).and_return(system_secret)
    allow(Rails.application.credentials).to receive(:atlas_system_token).and_return(system_secret)
  end

  let(:shared_nuid) { '000000155' }
  # The harness seeds this admin (role :admin); the account list/preferred set
  # are self/admin/system-gated, so an admin actor may read another NUID's.
  let(:admin_nuid) { ATLAS_RB_SERVER_ADMIN_NUID }

  def provision(email, affiliation, groups)
    AtlasRb::System::User.find_or_create(email: email, nuid: shared_nuid,
                                         groups: groups, name: 'P', affiliation: affiliation)
  end

  it 'provisions two accounts under one NUID without collapsing on NUID' do
    staff   = provision('p@northeastern.edu', 'staff', ['g:staff'])
    student = provision('p@husky.neu.edu', 'student', ['g:student'])

    expect(staff['email']).to eq('p@northeastern.edu')
    expect(staff['affiliation']).to eq('staff')
    expect(student['email']).to eq('p@husky.neu.edu')
    expect(User.where(nuid: shared_nuid).count).to eq(2)
  end

  it 'enumerates the accounts sharing a NUID' do
    provision('p@northeastern.edu', 'staff', ['g:staff'])
    provision('p@husky.neu.edu', 'student', ['g:student'])

    listing = AtlasRb::User.accounts(shared_nuid, nuid: admin_nuid)
    expect(listing['nuid']).to eq(shared_nuid)
    expect(listing['accounts'].pluck('email'))
      .to contain_exactly('p@northeastern.edu', 'p@husky.neu.edu')
  end

  it 'sets a preferred account and switches between accounts by email' do
    provision('p@northeastern.edu', 'staff', ['g:staff'])
    provision('p@husky.neu.edu', 'student', ['g:student'])

    AtlasRb::User.set_preferred(shared_nuid, email: 'p@husky.neu.edu', nuid: admin_nuid)

    # A switch adopts the named account's stored group set...
    expect(AtlasRb::Authentication.login(shared_nuid, email: 'p@northeastern.edu')['groups'])
      .to eq(['g:staff'])
    expect(AtlasRb::Authentication.login(shared_nuid, email: 'p@husky.neu.edu')['groups'])
      .to eq(['g:student'])
    # ...and with no account named, the preferred one resolves.
    expect(AtlasRb::Authentication.login(shared_nuid)['email']).to eq('p@husky.neu.edu')
  end
end
