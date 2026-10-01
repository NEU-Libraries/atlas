# frozen_string_literal: true

require 'rails_helper'

# AtlasRb::Person.list(q:) and Person.page over GET /people?q=, through the live
# server: the gem's q serialization, the pagination block Person.page keeps, the
# match on name, NUID prefix and account email, and the admin-only gate.
RSpec.describe 'People search via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { ATLAS_RB_SERVER_ADMIN_NUID }

  let!(:account) do
    User.create!(email: 'm.gasper-int@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000014', name: 'Licensed Resources Reader (DRS Fixture)', role: :standard)
  end

  before do
    PersonCreator.call(nuid: account.nuid, display_name: 'Mickey Gasper')
    PersonCreator.call(nuid: '000000015', display_name: 'Minnie Gasper')
    PersonCreator.call(nuid: '000000016', display_name: 'Donald Duck')
  end

  after { User.where(nuid: account.nuid).delete_all }

  it 'searches by display_name fragment, ordered by display_name' do
    people = AtlasRb::Person.list(q: 'GASP', nuid: admin_nuid)

    expect(people.pluck('display_name')).to eq(['Mickey Gasper', 'Minnie Gasper'])
    expect(people.first).to be_a(AtlasRb::Mash)
  end

  it 'searches by NUID prefix and by account email' do
    expect(AtlasRb::Person.list(q: '00000001', nuid: admin_nuid).size).to eq(3)
    expect(AtlasRb::Person.list(q: 'm.gasper-int@', nuid: admin_nuid).pluck('nuid')).to eq([account.nuid])
  end

  it 'keeps the pagination block, counting the matches' do
    result = AtlasRb::Person.page(q: 'gasper', page: 2, per_page: 1, nuid: admin_nuid)

    expect(result.people.pluck('display_name')).to eq(['Minnie Gasper'])
    expect(result.pagination).to include('count' => 2, 'pages' => 2, 'page' => 2)
  end

  it 'pages the whole registry when q is omitted' do
    result = AtlasRb::Person.page(per_page: 100, nuid: admin_nuid)

    expect(result.people.pluck('display_name')).to include('Donald Duck', 'Mickey Gasper')
    expect(result.pagination['count']).to eq(result.people.size)
  end

  it 'refuses a non-admin search with a ResourceError carrying the 403' do
    expect { AtlasRb::Person.list(q: 'gasper', nuid: account.nuid) }
      .to raise_error(AtlasRb::ResourceError) { |error| expect(error.status).to eq(403) }
  end
end
