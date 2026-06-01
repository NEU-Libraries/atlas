# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DescendantCollectionsQuery do
  # community → collection → nested_collection ; work hangs off collection
  let!(:community)        { Atlas.persister.save(resource: Community.new) }
  let!(:collection)       { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
  let!(:nested)           { Atlas.persister.save(resource: Collection.new(a_member_of: collection.id)) }
  let!(:deeper)           { Atlas.persister.save(resource: Collection.new(a_member_of: nested.id)) }
  let!(:work)             { Atlas.persister.save(resource: Work.new(a_member_of: collection.id)) }
  let!(:unrelated)        { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }

  it 'returns every collection beneath the given node, transitively' do
    result = described_class.call(collection).map(&:noid)

    expect(result).to contain_exactly(nested.noid, deeper.noid)
  end

  it 'returns the whole subtree (collections + sub-communities) for a community' do
    result = described_class.call(community).map(&:noid)

    expect(result).to contain_exactly(collection.noid, nested.noid, deeper.noid, unrelated.noid)
  end

  it 'never returns Works (they carry no ancestor_ids_ssim)' do
    result = described_class.call(community).map(&:id)

    expect(result).not_to include(work.id)
  end

  it 'returns [] for a leaf collection with no descendants' do
    expect(described_class.call(deeper)).to eq([])
  end
end
