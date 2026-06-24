# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FullTextIndexer do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  # Re-read the projected field straight off the resource's Solr doc.
  def all_text_in_solr(resource)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: 'all_text_timv' }
    ).dig('response', 'docs').first&.fetch('all_text_timv', nil)
  end

  describe '#to_solr' do
    it 'returns an empty hash for a Work whose text has not been extracted yet' do
      expect(described_class.new(resource: work).to_solr).to eq({})
    end

    it "projects the Work's stored full_text onto all_text_timv" do
      work.full_text = 'Running Boston Jon Masters'
      saved = Atlas.persister.save(resource: work)

      expect(described_class.new(resource: saved).to_solr).to eq(all_text_timv: 'Running Boston Jon Masters')
    end

    it 'returns an empty hash for non-Work resources' do
      expect(described_class.new(resource: collection).to_solr).to eq({})
      expect(described_class.new(resource: community).to_solr).to eq({})
      expect(described_class.new(resource: Blob.new).to_solr).to eq({})
      expect(described_class.new(resource: FileSet.new).to_solr).to eq({})
    end
  end

  describe 'end-to-end through the composite indexer' do
    it 'lands all_text_timv on the Work doc when the Work is saved, and is body-text searchable' do
      work.full_text = 'a quotation about the running of Boston'
      Atlas.persister.save(resource: work)

      # Stored content is retrievable only if the Solr field is stored=true
      # (an image-side schema concern); but the value is *indexed* regardless,
      # so a body-text term matches the Work doc — which is the search half.
      hits = Atlas.index_adapter.connection.get(
        'select', params: { q: 'all_text_timv:Boston', fl: 'id' }
      ).dig('response', 'docs')
      expect(hits.pluck('id')).to include(work.id.to_s)
    end

    it 're-projects on a plain re-save (survives reindex / reset:data)' do
      work.full_text = 'persisted body text'
      Atlas.persister.save(resource: work)
      # A reindex re-reads full_text from Postgres (source of truth) and
      # re-projects — no re-PATCH needed.
      Atlas.index_adapter.persister.save(resource: Work.find(work.noid))

      hits = Atlas.index_adapter.connection.get(
        'select', params: { q: 'all_text_timv:persisted', fl: 'id' }
      ).dig('response', 'docs')
      expect(hits.pluck('id')).to include(work.id.to_s)
    end
  end
end
