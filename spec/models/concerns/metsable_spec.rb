# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Metsable do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:file_set)   { FileSetCreator.call(work_id: work.noid, classification: Classification.generic) }

  def envelope_files_for(noid)
    object_root = Rails.root.join('tmp', 'files', noid[0..1], noid[2..3], noid)
    return [] unless object_root.exist?

    Dir.glob(object_root.join('v*', 'content', '*.json').to_s).map { |p| File.basename(p) }.uniq.sort
  end

  describe '#mets_xml=' do
    it 'stores the structural-metadata blob under the canonical mets.xml filename' do
      stored_id = file_set.mets_blob.file_identifiers.last.to_s
      expect(stored_id).to end_with('/mets.xml')
    end

    it 'projects the XML into a Metadata::METS json_attributes record' do
      expect(file_set.mets.json_attributes).to be_present
      expect(file_set.mets.agent).to eq('Atlas')
    end

    it 'emits a properties.json envelope for the new METS Blob' do
      expect(envelope_files_for(file_set.mets_blob.noid)).to include('properties.json', 'permissions.json')
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
