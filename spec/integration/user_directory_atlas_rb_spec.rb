# frozen_string_literal: true

require 'rails_helper'

# atlas_rb 1.3.2 — AtlasRb::User wraps the read-only user directory
# (UsersController#index / #show). Cerberus consumes this for the User Inbox
# recipient typeahead and sender-name display (and any surface that today
# renders a bare NUID). Exercised end-to-end through the live server: proves
# the gem's query-param serialization, Mash wrapping, the 404 → nil
# translation on find_by_nuid, and the excluded-role contract over the wire.
RSpec.describe 'User directory via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { ATLAS_RB_SERVER_ADMIN_NUID }

  def ensure_person(nuid:, name:, role: :standard)
    User.find_by(nuid: nuid) ||
      User.create!(email: "#{nuid}@example.invalid", password: SecureRandom.hex(16),
                   nuid: nuid, name: name, role: role)
  end

  let!(:jane)  { ensure_person(nuid: '001111111', name: 'Doe, Jane') }
  let!(:janet) { ensure_person(nuid: '002222222', name: 'Smith, Janet') }
  # Same-name guest row — must never surface through the directory.
  let!(:guest_jane) { ensure_person(nuid: '003333333', name: 'Jane, Guest', role: :guest) }

  after do
    User.where(nuid: [jane.nuid, janet.nuid, guest_jane.nuid]).delete_all
  end

  it 'searches by name fragment, name-ordered, excluding non-directory roles' do
    entries = AtlasRb::User.search('jane', nuid: admin_nuid)

    expect(entries.map { |e| e['nuid'] }).to eq([jane.nuid, janet.nuid])
    expect(entries.first.keys).to contain_exactly('nuid', 'name')
  end

  it 'wraps each entry in a Mash (dot access alongside string keys)' do
    entry = AtlasRb::User.search('Doe, Jane', nuid: admin_nuid).first

    expect(entry).to be_a(AtlasRb::Mash)
    expect(entry.nuid).to eq(jane.nuid)
    expect(entry.name).to eq(entry['name'])
  end

  it 'resolves a single NUID to nuid + name' do
    entry = AtlasRb::User.find_by_nuid(jane.nuid, nuid: admin_nuid)

    expect(entry).to be_a(AtlasRb::Mash)
    expect(entry.name).to eq('Doe, Jane')
  end

  it 'returns nil for unknown and excluded-role NUIDs alike' do
    expect(AtlasRb::User.find_by_nuid('no-such-nuid', nuid: admin_nuid)).to be_nil
    expect(AtlasRb::User.find_by_nuid(guest_jane.nuid, nuid: admin_nuid)).to be_nil
  end

  it 'batch-resolves NUIDs in one call, dropping unresolvable ones' do
    entries = AtlasRb::User.resolve([janet.nuid, guest_jane.nuid, jane.nuid, 'missing'],
                                    nuid: admin_nuid)

    # guest + unknown dropped; result is name-ordered.
    expect(entries.map { |e| e['nuid'] }).to eq([jane.nuid, janet.nuid])
  end

  it 'returns an empty list for a blank search' do
    expect(AtlasRb::User.search('', nuid: admin_nuid)).to eq([])
  end
end
