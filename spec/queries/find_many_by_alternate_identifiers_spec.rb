# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FindManyByAlternateIdentifiers do
  subject(:query) { Atlas.query.custom_queries }

  let!(:community)  { Atlas.persister.save(resource: Community.new) }
  let!(:collection) { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
  let!(:work)       { Atlas.persister.save(resource: Work.new(a_member_of: collection.id)) }

  it 'resolves many resources by NOID in one call' do
    result = query.find_many_by_alternate_identifiers(alternate_identifiers: [community.noid, work.noid])

    expect(result.map(&:noid)).to contain_exactly(community.noid, work.noid)
    expect(result.map(&:class)).to contain_exactly(Community, Work)
  end

  it 'drops unresolvable ids (result may be shorter than input, unordered)' do
    result = query.find_many_by_alternate_identifiers(
      alternate_identifiers: [collection.noid, 'does-not-exist']
    )

    expect(result.map(&:noid)).to contain_exactly(collection.noid)
  end

  it 'dedupes repeated ids' do
    result = query.find_many_by_alternate_identifiers(
      alternate_identifiers: [community.noid, community.noid]
    )

    expect(result.map(&:noid)).to contain_exactly(community.noid)
  end

  it 'returns [] for an empty id list without touching the database' do
    expect(query.find_many_by_alternate_identifiers(alternate_identifiers: [])).to eq([])
  end
end
