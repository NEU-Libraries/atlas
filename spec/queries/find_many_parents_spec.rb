# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FindManyParents do
  subject(:query) { Atlas.query.custom_queries }

  after { Atlas.persister.wipe! }

  # The two containment directions Relationships#parent tries, in its order: a
  # child naming its parent with a_member_of (the backbone), and a parent
  # listing the child in member_ids (FileSet -> Blob, the only direction a Blob
  # has).
  let!(:community)  { Atlas.persister.save(resource: Community.new) }
  let!(:collection) { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
  let!(:work)       { Atlas.persister.save(resource: Work.new(a_member_of: collection.id)) }
  let!(:blob_one)   { Atlas.persister.save(resource: Blob.new(use: Role.original_file.name)) }
  let!(:blob_two)   { Atlas.persister.save(resource: Blob.new(use: Role.service_file.name)) }
  let!(:file_set) do
    Atlas.persister.save(resource: FileSet.new(a_member_of: work.id, member_ids: [blob_one.id, blob_two.id]))
  end

  describe '#find_many_parents' do
    it 'resolves the forward a_member_of edge' do
      result = query.find_many_parents(resources: [collection, work])

      expect(result.fetch(collection.id.to_s).noid).to eq(community.noid)
      expect(result.fetch(work.id.to_s).noid).to eq(collection.noid)
    end

    it 'resolves the inverse member_ids edge, which is all a Blob has' do
      result = query.find_many_parents(resources: [blob_one, blob_two])

      expect(result.fetch(blob_one.id.to_s).noid).to eq(file_set.noid)
      expect(result.fetch(blob_two.id.to_s).noid).to eq(file_set.noid)
    end

    it 'answers both directions in one call' do
      result = query.find_many_parents(resources: [work, blob_one])

      expect(result.fetch(work.id.to_s).noid).to eq(collection.noid)
      expect(result.fetch(blob_one.id.to_s).noid).to eq(file_set.noid)
    end

    it 'matches what parent returns, per child' do
      [collection, work, file_set, blob_one, blob_two].each do |child|
        result = query.find_many_parents(resources: [child])

        expect(result[child.id.to_s]&.noid).to eq(child.parent&.noid)
      end
    end

    it 'omits a child with no parent rather than mapping it to nil' do
      orphan = Atlas.persister.save(resource: Blob.new(use: Role.original_file.name))

      result = query.find_many_parents(resources: [orphan, blob_one])

      expect(result).not_to have_key(orphan.id.to_s)
      expect(result.keys).to eq([blob_one.id.to_s])
    end

    it 'answers an empty hash for no resources' do
      expect(query.find_many_parents(resources: [])).to eq({})
    end

    # Compared within one direction at a time: the query count is set by which
    # directions the batch needs (a set of Blobs never touches the forward one),
    # not by how many resources it holds.
    it 'costs a fixed number of queries, whatever the batch holds' do
      inverse_one  = count_queries { query.find_many_parents(resources: [blob_one]) }
      inverse_many = count_queries { query.find_many_parents(resources: [blob_one, blob_two]) }
      expect(inverse_many.size).to eq(inverse_one.size)

      forward_one  = count_queries { query.find_many_parents(resources: [work]) }
      forward_many = count_queries { query.find_many_parents(resources: [work, collection, file_set]) }
      expect(forward_many.size).to eq(forward_one.size)
    end
  end
end
