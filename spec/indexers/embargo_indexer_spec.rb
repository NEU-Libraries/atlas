# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmbargoIndexer do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  after { Atlas.persister.wipe! }

  def embargo_fields_in_solr(resource)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: 'embargo_release_date_dtsi,embargoed_bsi' }
    ).dig('response', 'docs').first
  end

  def with_embargo(resource, date)
    resource.permissions = resource.permissions.merge(embargo: date)
    resource
  end

  describe '#to_solr' do
    it 'returns an empty hash for a Work with no embargo set' do
      result = described_class.new(resource: work).to_solr
      expect(result[:embargo_release_date_dtsi]).to be_nil
      expect(result[:embargoed_bsi]).to eq('false')
    end

    it 'projects a future release date as an active embargo' do
      with_embargo(work, '2999-01-01')

      result = described_class.new(resource: work).to_solr
      expect(result[:embargo_release_date_dtsi]).to eq(DateTime.parse('2999-01-01'))
      expect(result[:embargoed_bsi]).to eq('true')
    end

    it 'projects a past release date as an expired (non-active) embargo' do
      with_embargo(work, '2000-01-01')

      result = described_class.new(resource: work).to_solr
      expect(result[:embargo_release_date_dtsi]).to eq(DateTime.parse('2000-01-01'))
      expect(result[:embargoed_bsi]).to eq('false')
    end

    it 'returns an empty hash for non-Work resources' do
      expect(described_class.new(resource: collection).to_solr).to eq({})
      expect(described_class.new(resource: community).to_solr).to eq({})
      expect(described_class.new(resource: Blob.new).to_solr).to eq({})
      expect(described_class.new(resource: FileSet.new).to_solr).to eq({})
    end
  end

  describe 'end-to-end through the composite indexer' do
    it 'lands both fields on the Work doc when saved' do
      with_embargo(work, '2999-01-01')
      Atlas.persister.save(resource: work)

      doc = embargo_fields_in_solr(work)
      expect(Date.parse(doc['embargo_release_date_dtsi'])).to eq(Date.parse('2999-01-01'))
      expect(doc['embargoed_bsi']).to be(true)
    end

    it 'refreshes the fields on a later permissions-only save (Permissions tab, post-deposit)' do
      Atlas.persister.save(resource: work)
      expect(embargo_fields_in_solr(work)['embargo_release_date_dtsi']).to be_nil

      with_embargo(Work.find(work.noid), '2999-01-01').tap { |w| Atlas.persister.save(resource: w) }

      doc = embargo_fields_in_solr(work)
      expect(Date.parse(doc['embargo_release_date_dtsi'])).to eq(Date.parse('2999-01-01'))
      expect(doc['embargoed_bsi']).to be(true)
    end
  end
end
