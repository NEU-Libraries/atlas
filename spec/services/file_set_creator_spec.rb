# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FileSetCreator do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  describe '.call with a non-metadata classification' do
    it 'seeds a METS Blob directly into the FileSet member_ids with the structural_metadata role' do
      fs = described_class.call(work_id: work.noid, classification: Classification.generic)

      expect(fs.mets_blob).to be_present
      expect(fs.mets_blob.use).to eq(Role.structural_metadata.name)
      expect(fs.mets_blob.file_identifiers.last.to_s).to end_with('/mets.xml')
      expect(fs.member_ids).to include(fs.mets_blob.id)
    end

    it 'does not nest a sub-FileSet under the parent FileSet' do
      fs = described_class.call(work_id: work.noid, classification: Classification.generic)
      sub_fs = fs.children.find { |c| c.is_a?(FileSet) }
      expect(sub_fs).to be_nil
    end
  end

  describe '.call with the descriptive_metadata classification' do
    it 'does not seed METS' do
      fs = described_class.call(work_id: work.noid, classification: Classification.descriptive_metadata)
      expect(fs.mets_blob).to be_nil
    end
  end

  describe 'Work-level METS trigger (eager-after-finalize)' do
    def complete!(work)
      work.in_progress = false
      Atlas.persister.save(resource: work)
      WorkMETSRebuilder.call(work: work)
    end

    it 'does not rebuild the Work METS while the work is in progress' do
      described_class.call(work_id: work.noid, classification: Classification.image, position: 1)
      expect(Metadata::METS.find_by(valkyrie_id: work.noid)).to be_nil
    end

    it 'rebuilds the Work METS when a page is added to a completed work' do
      described_class.call(work_id: work.noid, classification: Classification.image, position: 1)
      complete!(work)

      described_class.call(work_id: work.noid, classification: Classification.image, position: 2)

      pages = Metadata::METS.find_by(valkyrie_id: work.noid).pages
      expect(pages.map(&:order)).to eq([1, 2])
    end

    it 'does not rebuild for non-page FileSets added post-completion' do
      complete!(work)
      created = Metadata::METS.find_by(valkyrie_id: work.noid).updated_at

      described_class.call(work_id: work.noid, classification: Classification.derivative)

      expect(Metadata::METS.find_by(valkyrie_id: work.noid).updated_at).to eq(created)
    end
  end
end
