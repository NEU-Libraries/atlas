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

  # Cerberus's suite drives a whole Atlas server in the test environment, which
  # never loads spec/support. Booted the same way here, outside RSpec, the test
  # adapter has to commit on save, or no fixture Cerberus creates is ever found.
  it 'commits on save in a test-environment Atlas that is not running the specs' do
    output, status = Open3.capture2e({ 'RAILS_ENV' => 'test' }, 'bin/rails', 'runner',
                                     'print Valkyrie::MetadataAdapter.find(:test_solr).soft_commit?',
                                     chdir: Rails.root.to_s)

    expect([status.success?, output.lines.last]).to eq([true, 'true'])
  end
end
