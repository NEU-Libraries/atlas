# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProvenanceIndexer do
  describe '#to_solr' do
    it 'projects depositor and proxy_uploader as single-string fields' do
      resource = Work.new(depositor: '000000123', proxy_uploader: '000000456')
      indexer  = described_class.new(resource: resource)

      expect(indexer.to_solr).to include(
        depositor_ssi:      '000000123',
        proxy_uploader_ssi: '000000456'
      )
    end

    it 'emits nil values for unstamped fields (no key suppression — Solr clears the field on update)' do
      resource = Work.new
      expect(described_class.new(resource: resource).to_solr).to eq(
        depositor_ssi:      nil,
        proxy_uploader_ssi: nil
      )
    end
  end
end
