# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NoIndex do
  after { Atlas.persister.wipe! }

  it 'names only spec files that exist' do
    missing = described_class.listed.reject { |path| Rails.root.join(path).exist? }
    expect(missing).to be_empty, "spec/no_index_files.txt names files that are gone: #{missing.join(', ')}"
  end

  describe 'an example run without an index', :no_index do
    it 'saves to Postgres alone' do
      expect(Valkyrie.config.metadata_adapter).to eq(Valkyrie::MetadataAdapter.find(:test_postgres_only))
      work = Atlas.persister.save(resource: Work.new)
      expect(Atlas.query.find_by(id: work.id).id).to eq(work.id)
    end

    it 'raises on a Solr read, naming the line to remove' do
      expect { RSolr.connect(url: SolrCore.url).get('select', params: { q: '*:*' }) }
        .to raise_error(NoIndex::SolrRead, %r{reads Solr \(select\).*remove spec/lib/no_index_spec\.rb})
    end

    it 'lets a Solr write through' do
      expect { Atlas.reindex(Atlas.persister.save(resource: Work.new)) }.not_to raise_error
    end
  end

  it 'indexes as usual everywhere else' do
    expect(Valkyrie.config.metadata_adapter).to eq(Valkyrie::MetadataAdapter.find(:test_composite_persister))
  end
end
