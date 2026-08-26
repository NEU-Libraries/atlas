# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FindPageOfModel do
  subject(:query) { Atlas.query.custom_queries }

  after { Atlas.persister.wipe! }

  let!(:community) { Atlas.persister.save(resource: Community.new) }
  let!(:collections) do
    Array.new(5) { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
  end

  describe '#count_of_model' do
    it 'counts only the requested model' do
      expect(query.count_of_model(model: Collection)).to eq(5)
      expect(query.count_of_model(model: Community)).to eq(1)
    end

    it 'costs one query' do
      expect(count_queries { query.count_of_model(model: Collection) }.size).to eq(1)
    end
  end

  describe '#find_page_of_model' do
    it 'returns the requested slice' do
      page = query.find_page_of_model(model: Collection, limit: 2, offset: 0)

      expect(page.size).to eq(2)
      expect(page.map(&:class).uniq).to eq([Collection])
    end

    it 'walks the model without overlap or omission across pages' do
      pages = [0, 2, 4].map { |offset| query.find_page_of_model(model: Collection, limit: 2, offset: offset) }

      expect(pages.flatten.map(&:noid)).to match_array(collections.map(&:noid))
    end

    it 'orders by id, matching find_all_of_model, so page boundaries are stable' do
      page = query.find_page_of_model(model: Collection, limit: 5, offset: 0)

      expect(page.map { |r| r.id.to_s }).to eq(page.map { |r| r.id.to_s }.sort)
    end

    it 'returns [] past the end' do
      expect(query.find_page_of_model(model: Collection, limit: 2, offset: 99)).to eq([])
    end

    it 'reads one page in one query, whatever the model holds' do
      expect(count_queries { query.find_page_of_model(model: Collection, limit: 1, offset: 0) }.size).to eq(1)
    end
  end
end
