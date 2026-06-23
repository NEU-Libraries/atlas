# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PersonalRootCreator do
  after { Atlas.persister.wipe! }

  def people_communities
    Atlas.query.find_all_of_model(model: Community).to_a
         .select { |c| c.depositor == described_class::PEOPLE_COMMUNITY_DEPOSITOR }
  end

  it 'mints a Collection owned by the nuid under the singleton People Community' do
    root = described_class.call(nuid: '001234567')

    expect(root).to be_a(Collection)
    expect(root.depositor).to eq('001234567')

    parent = root.parent
    expect(parent).to be_a(Community)
    expect(parent.depositor).to eq(described_class::PEOPLE_COMMUNITY_DEPOSITOR)
  end

  it 'reuses the singleton People Community across mints (idempotent)' do
    described_class.call(nuid: '001234567')
    described_class.call(nuid: '007654321')

    # Two roots, one shared People Community.
    expect(people_communities.size).to eq(1)
    expect(Atlas.query.find_all_of_model(model: Collection).count).to eq(2)
  end

  it 'mints the root public-but-unpromoted (public read grant)' do
    root = described_class.call(nuid: '001234567')

    expect(root).to be_public
    expect(root.read_groups).to include('public')
  end

  it 'flags the root as a personal root' do
    root = described_class.call(nuid: '001234567')

    expect(root.personal_root).to be(true)
  end

  it 'titles the People Community and the root for on-disk recoverability' do
    root   = described_class.call(nuid: '001234567')
    parent = root.parent

    expect(parent.decorate.plain_title).to eq('People')
    expect(root.decorate.plain_title).to eq('Personal Root')
  end
end
