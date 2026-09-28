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
    it 'leaves the date absent for a Work with no embargo set' do
      expect(described_class.new(resource: work).to_solr).to eq(embargo_release_date_dtsi: nil)
    end

    it 'projects the release date, past or future' do
      %w[2999-01-01 2000-01-01].each do |date|
        with_embargo(work, date)
        expect(described_class.new(resource: work).to_solr).to eq(embargo_release_date_dtsi: DateTime.parse(date))
      end
    end

    # A flag would be a snapshot that goes stale on the release date, because
    # nothing re-indexes a Work then. Readers compute it from the date instead.
    it 'indexes no embargoed flag' do
      with_embargo(work, '2999-01-01')
      expect(described_class.new(resource: work).to_solr).not_to have_key(:embargoed_bsi)
    end

    it 'returns an empty hash for non-Work resources' do
      expect(described_class.new(resource: collection).to_solr).to eq({})
      expect(described_class.new(resource: community).to_solr).to eq({})
      expect(described_class.new(resource: Blob.new).to_solr).to eq({})
      expect(described_class.new(resource: FileSet.new).to_solr).to eq({})
    end
  end

  describe 'end-to-end through the composite indexer' do
    it 'lands the date, and no flag, on the Work doc when saved' do
      with_embargo(work, '2999-01-01')
      Atlas.persister.save(resource: work)

      doc = embargo_fields_in_solr(work)
      expect(Date.parse(doc['embargo_release_date_dtsi'])).to eq(Date.parse('2999-01-01'))
      expect(doc).not_to have_key('embargoed_bsi')
    end

    it 'refreshes the date on a later permissions-only save (Permissions tab, post-deposit)' do
      Atlas.persister.save(resource: work)
      expect(embargo_fields_in_solr(work)['embargo_release_date_dtsi']).to be_nil

      with_embargo(Work.find(work.noid), '2999-01-01').tap { |w| Atlas.persister.save(resource: w) }

      doc = embargo_fields_in_solr(work)
      expect(Date.parse(doc['embargo_release_date_dtsi'])).to eq(Date.parse('2999-01-01'))
    end
  end
end
