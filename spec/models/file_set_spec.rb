# frozen_string_literal: true

# Generated with `rails generate valkyrie:model FileSet`
require 'rails_helper'
require 'valkyrie/specs/shared_specs'

RSpec.describe FileSet do
  let(:community) { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work) { WorkCreator.call(parent_id: collection.noid) }

  let(:file_set) { FileSetCreator.call(work_id: work.noid, classification: Classification.generic) }
  let(:resource_klass) { described_class }

  it_behaves_like 'a Valkyrie::Resource'

  describe '#files' do
    it 'includes the seeded METS Blob' do
      expect(file_set.files.size).to eq(1)
      expect(file_set.files.first.use).to eq(Role.structural_metadata.name)
    end
  end

  describe '#content_files' do
    it 'is empty until content Blobs are added (excludes the seeded METS Blob)' do
      expect(file_set.content_files).to be_empty
    end
  end
end
