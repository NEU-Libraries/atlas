# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FindPeopleByNuids do
  let!(:alice) { PersonCreator.call(nuid: '001111111', display_name: 'Alice') }
  let!(:bob)   { PersonCreator.call(nuid: '002222222', display_name: 'Bob') }

  after { Atlas.persister.wipe! }

  def queries
    Atlas.query.custom_queries
  end

  describe '#find_person_by_nuid' do
    it 'returns the matching Person' do
      expect(queries.find_person_by_nuid(nuid: '001111111')&.display_name).to eq('Alice')
    end

    it 'returns nil for an unknown nuid' do
      expect(queries.find_person_by_nuid(nuid: '009999999')).to be_nil
    end
  end

  describe '#find_people_by_nuids' do
    it 'batch-resolves, dropping unknown nuids' do
      result = queries.find_people_by_nuids(nuids: %w[001111111 002222222 000000000])
      expect(result.map(&:nuid)).to contain_exactly('001111111', '002222222')
    end

    it 'returns [] for empty input' do
      expect(queries.find_people_by_nuids(nuids: [])).to eq([])
    end
  end
end
