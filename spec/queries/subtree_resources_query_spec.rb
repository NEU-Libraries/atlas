# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SubtreeResourcesQuery do
  # community → collection → nested(collection); Works hang off both levels.
  # sibling is a second branch off the community, with its own Work.
  let!(:community)    { Atlas.persister.save(resource: Community.new) }
  let!(:collection)   { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
  let!(:nested)       { Atlas.persister.save(resource: Collection.new(a_member_of: collection.id)) }
  let!(:work_top)     { Atlas.persister.save(resource: Work.new(a_member_of: collection.id)) }
  let!(:work_deep)    { Atlas.persister.save(resource: Work.new(a_member_of: nested.id)) }
  let!(:sibling)      { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
  let!(:sibling_work) { Atlas.persister.save(resource: Work.new(a_member_of: sibling.id)) }

  it 'gathers the root, its descendant containers, and the Works beneath them' do
    result = described_class.call(collection).map(&:noid)

    expect(result).to contain_exactly(collection.noid, nested.noid, work_top.noid, work_deep.noid)
  end

  it 'is a superset of the container-only cascade — it includes descendant Works' do
    works = described_class.call(community).select { |r| r.is_a?(Work) }.map(&:noid)

    expect(works).to contain_exactly(work_top.noid, work_deep.noid, sibling_work.noid)
  end

  it 'returns just the resource itself for a leaf Work' do
    expect(described_class.call(work_deep).map(&:noid)).to eq([work_deep.noid])
  end

  it 'de-dupes a Work linked into more than one container' do
    # work_top is a member of `collection` (a_member_of) AND linked into a
    # second container via member_ids — it must still appear once.
    Atlas.persister.save(resource: Collection.new(a_member_of: community.id, member_ids: [work_top.id]))

    ids = described_class.call(community).map(&:id)

    expect(ids.count(work_top.id)).to eq(1)
  end
end
