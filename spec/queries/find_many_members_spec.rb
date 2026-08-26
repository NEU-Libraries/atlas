# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FindManyMembers do
  subject(:query) { Atlas.query.custom_queries }

  after { Atlas.persister.wipe! }

  # The two containment directions Relationships#children unions: a child
  # pointing up with a_member_of (the backbone), and a parent listing children
  # in member_ids (FileSet -> Blob).
  let!(:community)   { Atlas.persister.save(resource: Community.new) }
  let!(:collection)  { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
  let!(:other)       { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
  let!(:blob_one)    { Atlas.persister.save(resource: Blob.new(use: Role.original_file.name)) }
  let!(:blob_two)    { Atlas.persister.save(resource: Blob.new(use: Role.service_file.name)) }
  let!(:file_set) do
    Atlas.persister.save(resource: FileSet.new(member_ids: [blob_one.id, blob_two.id]))
  end

  describe '#find_many_members' do
    it 'groups the inverse a_member_of children under each parent' do
      result = query.find_many_members(resources: [community])

      expect(result.fetch(community.id.to_s).map(&:noid))
        .to contain_exactly(collection.noid, other.noid)
    end

    it 'answers several parents in one call' do
      result = query.find_many_members(resources: [community, file_set])

      expect(result.fetch(community.id.to_s).map(&:noid)).to include(collection.noid)
      expect(result.fetch(file_set.id.to_s).map(&:noid)).to eq([blob_one.noid, blob_two.noid])
    end

    it 'matches what children returns, per parent' do
      result = query.find_many_members(resources: [community, collection, file_set])

      [community, collection, file_set].each do |parent|
        expect(result.fetch(parent.id.to_s, []).map(&:noid)).to eq(parent.children.map(&:noid))
      end
    end

    it 'omits a parent with no children rather than returning an empty list' do
      expect(query.find_many_members(resources: [collection])).not_to have_key(collection.id.to_s)
    end

    it 'returns {} for an empty resource list' do
      expect(query.find_many_members(resources: [])).to eq({})
    end
  end

  describe '#find_many_ordered_members' do
    it 'returns member_ids children in stored order' do
      result = query.find_many_ordered_members(resources: [file_set])

      expect(result.fetch(file_set.id.to_s).map(&:noid)).to eq([blob_one.noid, blob_two.noid])
    end

    it 'preserves a reordering of member_ids' do
      reordered = Atlas.persister.save(
        resource: FileSet.find(file_set.noid).tap { |fs| fs.member_ids = [blob_two.id, blob_one.id] }
      )
      result = query.find_many_ordered_members(resources: [reordered])

      expect(result.fetch(reordered.id.to_s).map(&:noid)).to eq([blob_two.noid, blob_one.noid])
    end

    it 'matches what find_members returns' do
      result = query.find_many_ordered_members(resources: [file_set])

      expect(result.fetch(file_set.id.to_s).map(&:noid))
        .to eq(Atlas.query.find_members(resource: file_set).to_a.map(&:noid))
    end

    it 'ignores the inverse direction, unlike find_many_members' do
      expect(query.find_many_ordered_members(resources: [community])).to eq({})
    end

    it 'returns {} for an empty resource list' do
      expect(query.find_many_ordered_members(resources: [])).to eq({})
    end
  end

  it 'costs a fixed number of queries regardless of how many parents are asked for' do
    one  = count_queries { query.find_many_members(resources: [community]) }
    many = count_queries { query.find_many_members(resources: [community, collection, file_set]) }

    expect(many.size).to eq(one.size)
  end
end
