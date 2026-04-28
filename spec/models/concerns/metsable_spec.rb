# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Metsable do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:file_set)   { FileSetCreator.call(work_id: work.noid, classification: Classification.generic) }

  describe '#mets_xml=' do
    it 'stores the structural-metadata blob under the canonical mets.xml filename' do
      stored_id = file_set.mets_blob.file_identifiers.last.to_s
      expect(stored_id).to end_with('/mets.xml')
    end

    it 'projects the XML into a Metadata::METS json_attributes record' do
      expect(file_set.mets.json_attributes).to be_present
      expect(file_set.mets.agent).to eq('Atlas')
    end
  end

  describe '#mets_xml' do
    it 'round-trips the XML written to disk' do
      file_set.mets_xml = Rails.root.join('spec/fixtures/files/file-set-mets.xml').read
      expect(file_set.mets_xml).to include('urn:neu-drs:fixturefs')
      expect(file_set.mets_xml).to include('preservation')
    end
  end
end
