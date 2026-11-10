# frozen_string_literal: true

require 'rails_helper'

# RSolr takes the Faraday adapter as an option and falls back to Faraday's
# default without a word, so a renamed option or a missing gem would quietly
# put every Solr request back on a new connection. See docs/solr-indexing.md.
RSpec.describe 'the Valkyrie Solr connections' do
  %i[index_solr test_solr].each do |name|
    it "keeps the #{name} connection alive" do
      faraday = Valkyrie::MetadataAdapter.find(name).connection.connection

      expect(faraday.builder.adapter.klass).to eq(Faraday::Adapter::NetHttpPersistent)
    end
  end

  it 'answers through the kept-alive adapter' do
    expect(Atlas.index_adapter.connection.get('admin/ping')['status']).to eq('OK')
  end
end
