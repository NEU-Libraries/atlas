# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FileSetCreator do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  describe '.call with a non-metadata classification' do
    it 'auto-creates a structural_metadata child FileSet with a seeded METS Blob' do
      fs = described_class.call(work_id: work.noid, classification: Classification.generic)

      structural = fs.children.find { |c| c.is_a?(FileSet) && c.type == Classification.structural_metadata.name }
      expect(structural).to be_present
      expect(fs.mets_blob).to be_present
      expect(fs.mets_blob.file_identifiers.last.to_s).to end_with('/mets.xml')
    end
  end

  describe '.call with the descriptive_metadata classification' do
    it 'does not recurse into structural_metadata seeding' do
      fs = described_class.call(work_id: work.noid, classification: Classification.descriptive_metadata)

      structural = fs.children.find { |c| c.is_a?(FileSet) && c.type == Classification.structural_metadata.name }
      expect(structural).to be_nil
    end
  end

  describe '.call with the structural_metadata classification' do
    it 'does not recurse into further structural_metadata seeding' do
      parent_fs = described_class.call(work_id: work.noid, classification: Classification.generic)
      structural_child = parent_fs.children.find { |c| c.is_a?(FileSet) && c.type == Classification.structural_metadata.name }

      grandchild = structural_child.children.find { |c| c.is_a?(FileSet) && c.type == Classification.structural_metadata.name }
      expect(grandchild).to be_nil
    end
  end
end
