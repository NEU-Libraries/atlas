# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FullTextIndexer do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  # Re-read the projected field straight off the resource's Solr doc.
  def full_text_in_solr(resource)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: 'full_text_tesimv' }
    ).dig('response', 'docs').first&.fetch('full_text_tesimv', nil)
  end

  describe '#to_solr' do
    it 'returns an empty hash for a Work whose text has not been extracted yet' do
      expect(described_class.new(resource: work).to_solr).to eq({})
    end

    it "projects the Work's stored full_text onto full_text_tesimv" do
      work.full_text = 'Running Boston Jon Masters'
      saved = Atlas.persister.save(resource: work)

      expect(described_class.new(resource: saved).to_solr).to eq(full_text_tesimv: 'Running Boston Jon Masters')
    end

    it 'returns an empty hash for non-Work resources' do
      expect(described_class.new(resource: collection).to_solr).to eq({})
      expect(described_class.new(resource: community).to_solr).to eq({})
      expect(described_class.new(resource: Blob.new).to_solr).to eq({})
      expect(described_class.new(resource: FileSet.new).to_solr).to eq({})
    end
  end

  describe 'end-to-end through the composite indexer' do
    it 'lands full_text_tesimv on the Work doc when the Work is saved, and is body-text searchable' do
      work.full_text = 'a quotation about the running of Boston'
      Atlas.persister.save(resource: work)

      # The dedicated *_tesimv field is stored + indexed in the image, so a
      # body-text term matches the Work doc — the search half (highlighting the
      # stored value is a Cerberus-side hl.fl concern).
      hits = Atlas.index_adapter.connection.get(
        'select', params: { q: 'full_text_tesimv:Boston', fl: 'id' }
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
        'select', params: { q: 'full_text_tesimv:persisted', fl: 'id' }
      ).dig('response', 'docs')
      expect(hits.pluck('id')).to include(work.id.to_s)
    end
  end
end
