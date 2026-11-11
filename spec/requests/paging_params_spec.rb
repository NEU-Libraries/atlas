# frozen_string_literal: true

require 'rails_helper'

# Every list reads `page` and `per_page` the same way, whichever paginator
# backs it: a page below 1 or not a number is page 1, a page past the end is
# empty, and a per_page that is not a positive number gives the default. Left
# to itself, pagy raises on the first two, and the client sees a 500.
RSpec.describe 'Paging parameters', type: :request do
  before do
    3.times { |i| PersonCreator.call(nuid: format('0019%05d', i), display_name: "Person #{i}") }
  end

  describe 'a pagy list (GET /people)' do
    it 'reads a page below 1, or not a number, as page 1' do
      %w[0 -1 abc].each do |page|
        get '/people', params: { page: page }

        expect(response).to have_http_status(:ok), "page=#{page} answered #{response.status}"
        expect(response.parsed_body.dig('pagination', 'page')).to eq(1)
      end
    end

    it 'answers a page past the end with an empty page' do
      get '/people', params: { page: 999 }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['people']).to eq([])
      expect(response.parsed_body.dig('pagination', 'next')).to be_nil
    end

    it 'gives the default page size for a per_page that is not a positive number' do
      %w[0 abc].each do |per_page|
        get '/people', params: { per_page: per_page }

        expect(response.parsed_body.dig('pagination', 'items')).to eq(Pagy::DEFAULT[:items])
      end
    end
  end

  describe 'a search-backed list (GET /resources/search)' do
    it 'gives the default page size for a per_page that is not a positive number' do
      %w[0 abc].each do |per_page|
        get '/resources/search', params: { per_page: per_page }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig('pagination', 'per_page')).to eq(SearchQuery::DEFAULT_PER_PAGE)
      end
    end
  end
end
