# frozen_string_literal: true

require 'rails_helper'

# Regression guard for the read-path N+1 fixes. Each example renders the same
# endpoint over a small set and then a larger one, and asserts the query count
# did not move. Asserting the shape (fixed, not per-row) rather than a literal
# budget keeps the specs honest without pinning them to an exact number that
# any unrelated change would churn.
describe 'read-path query budget', type: :controller do
  render_views

  after { Atlas.persister.wipe! }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  describe WorksController do
    let!(:first_work) { WorkCreator.call(parent_id: collection.noid) }

    it 'reads the index in a fixed number of queries, whatever the page holds' do
      one = count_queries { get :index, as: :json }
      expect(response).to have_http_status(:success)

      Array.new(4) { WorkCreator.call(parent_id: collection.noid) }
      many = count_queries { get :index, as: :json }

      expect(response.parsed_body['works'].size).to eq(5)
      expect(many.size).to eq(one.size)
    end

    it 'reads a page listing in a fixed number of queries, whatever the Work holds' do
      Atlas.persister.save(
        resource: FileSet.new(type: Classification.image.name, a_member_of: first_work.id)
      )
      one = count_queries { get :file_sets, params: { id: first_work.noid }, as: :json }
      expect(response).to have_http_status(:success)

      Array.new(4) do
        Atlas.persister.save(
          resource: FileSet.new(type: Classification.image.name, a_member_of: first_work.id)
        )
      end
      many = count_queries { get :file_sets, params: { id: first_work.noid }, as: :json }

      expect(response.parsed_body.size).to eq(5)
      expect(many.size).to eq(one.size)
    end

    it 'reads the flat asset listing in a fixed number of queries' do
      # Starts at one FileSet, not zero: with nothing to resolve the batched
      # member read is skipped altogether, which is not the comparison here.
      Atlas.persister.save(
        resource: FileSet.new(type: Classification.image.name, a_member_of: first_work.id)
      )
      one = count_queries { get :assets, params: { id: first_work.noid }, as: :json }
      expect(response).to have_http_status(:success)

      Array.new(4) do
        Atlas.persister.save(
          resource: FileSet.new(type: Classification.image.name, a_member_of: first_work.id)
        )
      end
      many = count_queries { get :assets, params: { id: first_work.noid }, as: :json }

      expect(many.size).to eq(one.size)
    end
  end

  describe ResourcesController do
    let!(:works) { Array.new(5) { WorkCreator.call(parent_id: collection.noid) } }

    it 'resolves a batch in a fixed number of queries, whatever the batch holds' do
      one = count_queries { post :find_many, params: { ids: [works.first.noid] }, as: :json }
      expect(response).to have_http_status(:success)

      many = count_queries { post :find_many, params: { ids: works.map(&:noid) }, as: :json }

      expect(response.parsed_body.size).to eq(5)
      expect(many.size).to eq(one.size)
    end
  end

  describe PeopleController do
    let!(:sibling) { CommunityCreator.call(parent_id: community.noid) }

    it 'reads the index in a fixed number of queries, whatever the page holds' do
      Atlas.persister.save(resource: Person.new(nuid: '000000101', affiliated_community_ids: [community.id]))
      one = count_queries { get :index, as: :json }
      expect(response).to have_http_status(:success)

      Array.new(4) do |n|
        Atlas.persister.save(
          resource: Person.new(nuid: "00000020#{n}", affiliated_community_ids: [community.id, sibling.id])
        )
      end
      many = count_queries { get :index, as: :json }

      expect(response.parsed_body['people'].size).to eq(5)
      expect(many.size).to eq(one.size)
    end
  end
end
