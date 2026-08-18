# frozen_string_literal: true

require 'rails_helper'

# MODSVersionHistory reports *content-distinct* MODS states, not raw OCFL
# revisions. The descriptive-metadata Blob shares its OCFL object with its own
# preservation envelope, and OCFL state is cumulative — so an envelope re-write
# (e.g. the atlas:preservation:backfill_envelopes task) cuts a new version that
# still carries descMetadata.xml at its prior, unchanged digest. These specs
# pin the read-time coalescing that collapses those byte-identical runs.
RSpec.describe MODSVersionHistory do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  let(:content_a) { Rails.root.join('spec/fixtures/files/work-mods.xml').read }
  let(:content_b) { Rails.root.join('spec/fixtures/files/collection-mods.xml').read }

  # Version labels are only deterministic with clean OCFL storage (the DB NOID
  # minter rolls back per example, so NOIDs repeat). See the request spec for
  # the fuller note.
  before { FileUtils.rm_rf(Rails.root.join('tmp/files')) }
  after { Atlas.persister.wipe! }

  def descriptors_for(resource)
    described_class.descriptors(resource: Work.find(resource.noid))
  end

  # mods_xml= persists the Blob (and the JSON copy) itself; the Work resource
  # is untouched, so there's nothing to save on it. Reload fresh each call so
  # the Blob's file_identifiers / optimistic-lock token are current.
  def set_mods(work, xml)
    Work.find(work.noid).mods_xml = xml
  end

  # Which version a seed lands in depends on how many versions the write path
  # spends getting there, so capture it rather than name it.
  def ordinal(label)
    label.delete_prefix('v').to_i
  end

  describe '#descriptors' do
    it 'collapses envelope-churn revisions (identical digest) to the earliest version' do
      work = WorkCreator.call(parent_id: collection.noid)
      seeded = descriptors_for(work).first[:version_id]
      # Re-emit the Blob's envelope twice WITHOUT touching MODS — exactly what
      # the backfill task does. Each call cuts a version that carries
      # descMetadata.xml forward unchanged.
      2.times { Work.find(work.noid).mods_blob.write_preservation_envelope! }

      descriptors = descriptors_for(work)
      expect(descriptors.length).to eq(1)
      expect(descriptors.first[:version_id]).to eq(seeded) # churn does not advance it
    end

    it 'collapses consecutive byte-identical edits, keeping the earliest' do
      work = WorkCreator.call(parent_id: collection.noid)
      seeded = descriptors_for(work).first[:version_id]
      set_mods(work, content_a)
      set_mods(work, content_a) # same bytes -> a no-op revision

      descriptors = descriptors_for(work)
      # The seed plus the first of the identical A-pair; the second collapses.
      expect(descriptors.length).to eq(2)
      expect(descriptors.last[:version_id]).to eq(seeded)
      expect(ordinal(descriptors.first[:version_id])).to be > ordinal(seeded)
    end

    it 'keeps a non-consecutive return to a prior content state' do
      work = WorkCreator.call(parent_id: collection.noid)
      set_mods(work, content_a)
      set_mods(work, content_b)
      set_mods(work, content_a) # same bytes as the first A, but NOT consecutive

      # A→B→A: the second A is a real change back, so all four states stand.
      expect(descriptors_for(work).length).to eq(4)
    end

    it 'reports content-distinct edits newest-first' do
      work = WorkCreator.call(parent_id: collection.noid)
      set_mods(work, content_a)
      set_mods(work, content_b)

      ordinals = descriptors_for(work).map { |d| ordinal(d[:version_id]) }
      expect(ordinals).to eq(ordinals.sort.reverse)
    end

    it 'retains version_ids that still round-trip through fetch_xml' do
      work = WorkCreator.call(parent_id: collection.noid)
      set_mods(work, content_a)
      2.times { Work.find(work.noid).mods_blob.write_preservation_envelope! }

      history = described_class.new(Work.find(work.noid))
      history.descriptors.each do |descriptor|
        expect(history.fetch_xml(descriptor[:version_id])).to be_a(String)
      end
    end

    it 'coalesces from inventory digests alone — never fetches content' do
      work = WorkCreator.call(parent_id: collection.noid)
      set_mods(work, content_a)

      adapter = Valkyrie.config.storage_adapter
      expect(adapter).not_to receive(:find_by)
      expect(adapter).not_to receive(:find_versions)
      descriptors_for(work)
    end
  end

  describe 'Valkyrie::Storage::OCFL#find_version_metadata' do
    it 'surfaces a per-version digest; envelope-carried versions share the seed digest' do
      work = WorkCreator.call(parent_id: collection.noid)
      2.times { Work.find(work.noid).mods_blob.write_preservation_envelope! }

      blob = Work.find(work.noid).mods_blob
      metadata = Valkyrie.config.storage_adapter.find_version_metadata(id: blob.latest_revision)

      expect(metadata).to all(include(:digest))
      # descMetadata.xml was written once (the seed); the envelope re-writes
      # carry it forward unchanged, so every entry shares one digest.
      expect(metadata.pluck(:digest).uniq.length).to eq(1)
    end
  end
end
