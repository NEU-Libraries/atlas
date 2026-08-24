# frozen_string_literal: true

require 'rails_helper'

# The pipeline-failure half of the Work lifecycle, over the real HTTP boundary.
# `complete` says the deposit finished; `incomplete` says something downstream
# of it gave up. Before this pair existed a give-up handler could only write a
# log line, so a deposit whose rendition exhausted its retries was invisible.
RSpec.describe 'Work incomplete state via atlas_rb', :atlas_rb_server do
  # Admin (wildcard) — the cheapest principal that satisfies the :update gate
  # the incomplete pair rides.
  let(:admin_nuid) { '000000004' }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  def solr_flags_for(work)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{Work.find(work.noid).id}"), fl: 'incomplete_bsi,incomplete_reason_ssi' }
    ).dig('response', 'docs').first
  end

  describe '.mark_incomplete' do
    it 'sets the flag and the reason, and echoes them on the returned Work' do
      work = WorkCreator.call(parent_id: collection.noid)

      result = AtlasRb::Work.mark_incomplete(work.noid, reason: 'pdf_rendition_gave_up', nuid: admin_nuid)

      expect(result['incomplete']).to        be true
      expect(result['incomplete_reason']).to eq('pdf_rendition_gave_up')
      expect(AtlasRb::Work.find(work.noid, nuid: admin_nuid)['incomplete']).to be true
    end

    it 'is false with a null reason on a Work nobody has flagged' do
      work = WorkCreator.call(parent_id: collection.noid)

      found = AtlasRb::Work.find(work.noid, nuid: admin_nuid)
      expect(found['incomplete']).to        be false
      expect(found['incomplete_reason']).to be_nil
    end

    it 'accepts a token Atlas has never seen — the vocabulary is the caller’s' do
      work = WorkCreator.call(parent_id: collection.noid)

      result = AtlasRb::Work.mark_incomplete(work.noid, reason: 'some_future_cerberus_job_gave_up', nuid: admin_nuid)

      expect(result['incomplete_reason']).to eq('some_future_cerberus_job_gave_up')
    end

    it 'is idempotent — the last reason wins' do
      work = WorkCreator.call(parent_id: collection.noid)

      AtlasRb::Work.mark_incomplete(work.noid, reason: 'pdf_rendition_gave_up', nuid: admin_nuid)
      result = AtlasRb::Work.mark_incomplete(work.noid, reason: 'full_text_gave_up', nuid: admin_nuid)

      expect(result['incomplete']).to        be true
      expect(result['incomplete_reason']).to eq('full_text_gave_up')
    end

    it 'flags without hiding: the Work stays readable and un-tombstoned' do
      work = WorkCreator.call(parent_id: collection.noid)
      work.publicize
      Atlas.persister.save(resource: work)

      AtlasRb::Work.mark_incomplete(work.noid, reason: 'derivatives_gave_up', nuid: admin_nuid)

      found = AtlasRb::Work.find(work.noid, nuid: admin_nuid)
      expect(found).not_to           be_nil
      expect(found['tombstoned']).to be false
      expect(Work.find(work.noid).read_groups.to_a).to eq(['public'])
    end

    it 'raises NotFoundError when the id names no Work' do
      expect do
        AtlasRb::Work.mark_incomplete('nonexistent', reason: 'ingest_gave_up', nuid: admin_nuid)
      end.to raise_error(AtlasRb::NotFoundError)
    end
  end

  describe '.clear_incomplete' do
    it 'clears the flag and the reason together' do
      work = WorkCreator.call(parent_id: collection.noid)
      AtlasRb::Work.mark_incomplete(work.noid, reason: 'media_rendition_gave_up', nuid: admin_nuid)

      result = AtlasRb::Work.clear_incomplete(work.noid, nuid: admin_nuid)

      expect(result['incomplete']).to        be false
      expect(result['incomplete_reason']).to be_nil
    end

    it 'is a no-op on a Work that was never flagged' do
      work = WorkCreator.call(parent_id: collection.noid)

      expect(AtlasRb::Work.clear_incomplete(work.noid, nuid: admin_nuid)['incomplete']).to be false
    end

    it 'raises NotFoundError when the id names no Work' do
      expect do
        AtlasRb::Work.clear_incomplete('nonexistent', nuid: admin_nuid)
      end.to raise_error(AtlasRb::NotFoundError)
    end
  end

  # The pill is rendered from the search document, so an unindexed field cannot
  # drive it and a per-row fetch would defeat the result list.
  describe 'the Solr projection' do
    it 'lands both fields on the Work document, and withdraws them on repair' do
      work = WorkCreator.call(parent_id: collection.noid)

      AtlasRb::Work.mark_incomplete(work.noid, reason: 'pdf_rendition_gave_up', nuid: admin_nuid)
      flagged = solr_flags_for(work)
      expect(flagged['incomplete_bsi']).to        be true
      expect(flagged['incomplete_reason_ssi']).to eq('pdf_rendition_gave_up')

      AtlasRb::Work.clear_incomplete(work.noid, nuid: admin_nuid)
      repaired = solr_flags_for(work)
      expect(repaired['incomplete_bsi']).to be false
      expect(repaired).not_to have_key('incomplete_reason_ssi')
    end
  end

  describe '.list(incomplete: true)' do
    it 'returns only the flagged Works, each carrying its reason' do
      AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
      flagged = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
      AtlasRb::Work.mark_incomplete(flagged['id'], reason: 'ingest_gave_up', nuid: admin_nuid)

      works = AtlasRb::Work.list(incomplete: true, nuid: admin_nuid)['works']

      expect(works.pluck('id')).to eq([flagged['id']])
      expect(works.first['incomplete_reason']).to eq('ingest_gave_up')
    end

    it 'combines with in_progress: false — finished, but degraded' do
      AtlasRb::Work.create(collection.noid, nuid: admin_nuid) # still depositing
      clean = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
      AtlasRb::Work.complete(clean['id'], nuid: admin_nuid)
      degraded = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
      AtlasRb::Work.complete(degraded['id'], nuid: admin_nuid)
      AtlasRb::Work.mark_incomplete(degraded['id'], reason: 'derivatives_gave_up', nuid: admin_nuid)

      works = AtlasRb::Work.list(in_progress: false, incomplete: true, nuid: admin_nuid)['works']

      expect(works.pluck('id')).to eq([degraded['id']])
    end

    it 'lists every Work when neither filter is supplied' do
      2.times { AtlasRb::Work.create(collection.noid, nuid: admin_nuid) }

      expect(AtlasRb::Work.list(nuid: admin_nuid)['works'].size).to eq(2)
    end
  end
end
