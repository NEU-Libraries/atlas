# frozen_string_literal: true

require 'rails_helper'

RSpec.describe OAIIndexer do
  include ActiveSupport::Testing::TimeHelpers

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  def solr_field(resource, field)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: field }
    ).dig('response', 'docs').first&.fetch(field, nil)
  end

  describe '#to_solr' do
    it "carries the Work's MODS and datestamp" do
      fields = described_class.new(resource: work).to_solr

      expect(fields[:mods_xml_ss]).to include('<mods:mods')
      expect(fields[:oai_datestamp_dtsi]).to eq(work.updated_at.utc.iso8601)
    end

    it 'returns an empty hash for anything that is not a Work' do
      expect(described_class.new(resource: collection).to_solr).to eq({})
      expect(described_class.new(resource: community).to_solr).to eq({})
      expect(described_class.new(resource: FileSet.new).to_solr).to eq({})
      expect(described_class.new(resource: Blob.new).to_solr).to eq({})
    end
  end

  describe 'end-to-end through the composite indexer' do
    it 'lands both fields on the Work doc' do
      Atlas.persister.save(resource: Work.find(work.noid))

      expect(solr_field(work, 'mods_xml_ss')).to include('<mods:mods')
      expect(solr_field(work, 'oai_datestamp_dtsi')).to be_present
    end
  end

  # The core of the whole change. Valkyrie's own updated_at_dtsi is set to
  # Time.current inside its Solr ModelConverter, so it is INDEX time: the
  # mods_xml_ss backfill this feature needs would stamp every Work with one
  # instant and force Digital Commonwealth into a full re-harvest. Reading
  # Postgres's updated_at instead means the fix survives its own backfill.
  describe 'datestamp semantics' do
    it 'does not move on a Solr-only reindex' do
      Atlas.persister.save(resource: Work.find(work.noid))
      before = solr_field(work, 'oai_datestamp_dtsi')

      # What POST /resources/:id/reindex calls.
      Atlas.index_adapter.persister.save(resource: Work.find(work.noid))

      expect(solr_field(work, 'oai_datestamp_dtsi')).to eq(before)
    end

    it 'moves on a real edit' do
      Atlas.persister.save(resource: Work.find(work.noid))
      before = solr_field(work, 'oai_datestamp_dtsi')

      travel_to(2.days.from_now) do
        set_mods_primary_title!(work, 'Revised')
        Atlas.persister.save(resource: Work.find(work.noid))
      end

      expect(solr_field(work, 'oai_datestamp_dtsi')).to be > before
    end

    # Valkyrie's field is the trap this replaces; pin the difference so nobody
    # "simplifies" the indexer back onto it.
    it 'is not Valkyrie updated_at_dtsi, which a reindex does rewrite' do
      Atlas.persister.save(resource: Work.find(work.noid))
      before = solr_field(work, 'updated_at_dtsi')

      travel_to(2.days.from_now) do
        Atlas.index_adapter.persister.save(resource: Work.find(work.noid))
      end

      expect(solr_field(work, 'updated_at_dtsi')).not_to eq(before)
    end
  end
end
