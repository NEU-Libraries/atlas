# frozen_string_literal: true

require 'swagger_helper'

# The response shape and parameters, which drive the OpenAPI entry. Who finds
# what is search_filters_spec.rb.
RSpec.describe 'Search', type: :request do
  let(:community)  { public_community! }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  after { Atlas.persister.wipe! }

  def finished_work(title)
    w = WorkCreator.call(parent_id: collection.noid)
    Work.find(w.noid).mods_xml = Rails.root.join('spec/fixtures/files/work-mods.xml').read.sub("What's New", title)
    w = Work.find(w.noid)
    w.in_progress = false
    Atlas.persister.save(resource: w)
  end

  path '/resources/search' do
    get 'Search the catalog' do
      tags 'Resources'
      produces 'application/json'
      description <<~DESC
        Keyword search over Works, Collections, Communities and People, ranked
        by relevance and read straight off Solr. The text is matched with the
        same field weights Cerberus's search bar uses, because both come from
        the Solr core's search handler.

        Results are gated to what the caller may read: public, one of the
        caller's read or edit groups, the caller as an edit user, or the caller
        as the depositor. Admins see everything. Tombstoned items, featured
        Collections, personal roots and the People Community never appear. An
        unfinished deposit appears only to its depositor and to staff.

        A blank `q` browses everything the caller may read, newest first.
        `type` narrows to one type. Pagination via `page` / `per_page`
        (default 25, capped at 100). An unknown `type` → 400.
      DESC
      parameter name: :q, in: :query, type: :string, required: false,
                description: 'Search text. Omit to browse.'
      parameter name: :type, in: :query, type: :string, required: false,
                enum: SearchQuery::TYPES, description: 'Narrow to one type. Omit to search all four.'
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :per_page, in: :query, type: :integer, required: false

      let(:q)        { nil }
      let(:type)     { nil }
      let(:page)     { nil }
      let(:per_page) { nil }

      response '200', 'matching resources, most relevant first' do
        schema '$ref' => '#/components/schemas/SearchResults'
        let!(:hit)  { finished_work('Albatross almanac') }
        let!(:miss) { finished_work('Unrelated title') }
        let(:q)     { 'albatross' }

        run_test! do |response|
          body = response.parsed_body
          expect(body['results'].pluck('noid')).to eq([hit.noid])
          row = body['results'].first
          expect(row['klass']).to eq('Work')
          expect(row['title']).to start_with('Albatross almanac')
          expect(row['creators']).not_to be_empty
          expect(row['year']).to eq('2017')
          expect(body['pagination']).to include('total' => 1, 'page' => 1, 'per_page' => 25)
        end
      end

      response '200', 'narrowed to one type' do
        schema '$ref' => '#/components/schemas/SearchResults'
        let!(:work) { finished_work('Albatross almanac') }
        let(:type)  { 'Collection' }

        run_test! do |response|
          expect(response.parsed_body['results'].pluck('klass').uniq).to eq(['Collection'])
        end
      end

      response '400', 'unknown type' do
        let(:type) { 'Blob' }

        run_test! do |response|
          expect(response.parsed_body['error']).to include('unknown type Blob')
        end
      end
    end
  end

  it 'pages with a stable order and clamps per_page to 100' do
    works = Array.new(3) { |i| finished_work("Albatross #{i}") }

    get '/resources/search', params: { q: 'albatross', per_page: 2, page: 1 }
    first = response.parsed_body
    get '/resources/search', params: { q: 'albatross', per_page: 2, page: 2 }
    second = response.parsed_body

    expect(first['pagination']).to include('total' => 3, 'pages' => 2)
    expect(first['results'].pluck('noid') + second['results'].pluck('noid'))
      .to match_array(works.map(&:noid))

    get '/resources/search', params: { per_page: 500 }
    expect(response.parsed_body.dig('pagination', 'per_page')).to eq(100)
  end
end
