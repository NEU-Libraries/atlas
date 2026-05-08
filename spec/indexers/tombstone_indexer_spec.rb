# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TombstoneIndexer do
  describe '#to_solr' do
    it 'emits the three tombstone fields with Solr suffixes' do
      resource = Work.new(
        tombstoned: true,
        tombstoned_at: DateTime.parse('2026-05-08T12:00:00Z'),
        tombstoned_by: '000000002'
      )

      expect(described_class.new(resource: resource).to_solr).to eq(
        tombstoned_bsi: 'true',
        tombstoned_at_dti: DateTime.parse('2026-05-08T12:00:00Z'),
        tombstoned_by_ssi: '000000002'
      )
    end

    it "stringifies tombstoned as 'false' when not set" do
      resource = Work.new

      result = described_class.new(resource: resource).to_solr

      expect(result[:tombstoned_bsi]).to eq('false')
      expect(result[:tombstoned_at_dti]).to be_nil
      expect(result[:tombstoned_by_ssi]).to be_nil
    end
  end
end
