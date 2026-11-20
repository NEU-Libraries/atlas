# frozen_string_literal: true

require 'rails_helper'

RSpec.describe METSRebuilder do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  let(:fixture_path) { Rails.root.join('spec/fixtures/files/example.png').to_s }

  def reload(file_set)
    FileSet.find(file_set.id)
  end

  def file_ids_in(file_set)
    Nokogiri::XML(reload(file_set).mets_xml)
            .xpath('//m:fileSec//m:file/@ID', m: METSBuilder::METS_NS)
            .map(&:value)
  end

  describe '.call after a Blob is added' do
    it 'regenerates METS with the new Blob in fileSec' do
      blob = BlobCreator.call(path: fixture_path, work_id: work.noid, original_filename: 'example.png')
      fs = blob.parent

      expect(file_ids_in(fs)).to include("f-#{blob.noid}")
    end

    it 'preserves CREATEDATE across regenerations' do
      blob = BlobCreator.call(path: fixture_path, work_id: work.noid, original_filename: 'example.png')
      fs = blob.parent
      created_at = Nokogiri::XML(reload(fs).mets_xml)
                           .at_xpath('//m:metsHdr/@CREATEDATE', m: METSBuilder::METS_NS).value

      described_class.call(file_set: fs)

      reread = Nokogiri::XML(reload(fs).mets_xml)
                       .at_xpath('//m:metsHdr/@CREATEDATE', m: METSBuilder::METS_NS).value
      expect(reread).to eq(created_at)
    end

    it 'is a no-op when content is unchanged (does not bump OCFL version)' do
      blob = BlobCreator.call(path: fixture_path, work_id: work.noid, original_filename: 'example.png')
      fs = blob.parent
      versions_before = reload(fs).mets_blob.versions

      described_class.call(file_set: fs)

      expect(reload(fs).mets_blob.versions).to eq(versions_before)
    end
  end

  describe 'the file entries' do
    let(:blob) { BlobCreator.call(path: fixture_path, work_id: work.noid, original_filename: 'example.png') }
    let(:doc)  { Nokogiri::XML(reload(blob.parent).mets_xml) }

    def m(xpath)
      doc.at_xpath(xpath, 'm' => METSBuilder::METS_NS, 'xlink' => METSBuilder::XLINK_NS)
    end

    it 'carries the recorded digest as CHECKSUM and CHECKSUMTYPE' do
      algorithm, value = blob.digest.split(':', 2)
      file = m("//m:file[@ID='f-#{blob.noid}']")

      expect(file['CHECKSUM']).to eq(value)
      expect(file['CHECKSUMTYPE']).to eq(METSBuilder::CHECKSUM_TYPES.fetch(algorithm))
    end

    it 'locates the file by its OCFL version id, not as a URL' do
      flocat = m("//m:file[@ID='f-#{blob.noid}']/m:FLocat")

      expect(flocat['LOCTYPE']).to eq('OTHER')
      expect(flocat['OTHERLOCTYPE']).to eq('OCFL')
      expect(flocat['xlink:href']).to eq(blob.latest_revision.to_s)
    end

    it 'validates against the METS schema' do
      expect_valid_mets(reload(blob.parent).mets_xml)
    end
  end

  describe '.call with a metadata FileSet' do
    it 'is a no-op for descriptive_metadata' do
      desc_fs = work.children.find { |c| c.is_a?(FileSet) && c.type == Classification.descriptive_metadata.name }
      expect { described_class.call(file_set: desc_fs) }.not_to raise_error
    end
  end

  describe 'fileSec contents' do
    it 'excludes the METS Blob itself' do
      blob = BlobCreator.call(path: fixture_path, work_id: work.noid, original_filename: 'example.png')
      fs = blob.parent

      expect(file_ids_in(fs)).not_to include("f-#{fs.mets_blob.noid}")
    end
  end

  describe '.call when the parent FileSet has been removed' do
    it 'returns nil instead of raising' do
      expect { described_class.call(file_set: nil) }.not_to raise_error
    end
  end
end
