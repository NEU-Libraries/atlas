# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MetadataRecords::DarwinCore do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:dwc_xml)    { Rails.root.join('spec/fixtures/files/dwc.xml').read }

  after { Atlas.persister.wipe! }

  def darwin_core_file_set(resource)
    Work.find(resource.id).children.find { |c| c.is_a?(FileSet) && c.type == Classification.darwin_core.name }
  end

  it 'holds no record, and creates no FileSet, until the first write' do
    expect(work.darwin_core?).to be(false)
    expect(work.metadata_formats).to eq([])
    expect(darwin_core_file_set(work)).to be_nil
  end

  describe '#darwin_core_xml=' do
    before { work.darwin_core_xml = dwc_xml }

    it 'stores the document under dwc.xml in a Blob on a :darwin_core FileSet' do
      blob = Work.find(work.id).darwin_core_blob
      expect(blob.use).to eq(Role.darwin_core.name)
      expect(blob.file_identifiers.last.to_s).to end_with('/dwc.xml')
    end

    it 'serves the stored bytes back unchanged' do
      expect(Work.find(work.id).darwin_core_xml).to eq(dwc_xml)
    end

    it 'projects the terms into the access copy and advertises the format' do
      reloaded = Work.find(work.id)
      expect(reloaded.darwin_core.json_attributes).to include('catalogNumber' => 'MVZ:Mamm:14523')
      expect(reloaded.metadata_formats).to eq(['dwc'])
    end

    # Classification.metadata? drives every content listing; the record must
    # not read as a page.
    it 'keeps the record out of the page listing and the asset list' do
      expect(darwin_core_file_set(work).page?).to be(false)
      expect(Work.find(work.id).page_file_sets).to be_empty
    end

    it 'appends a version on a second write rather than a second Blob' do
      work.darwin_core_xml = Rails.root.join('spec/fixtures/files/dwc-other.xml').read
      reloaded = Work.find(work.id)
      expect(darwin_core_file_set(work).member_ids.size).to eq(1)
      expect(reloaded.darwin_core_blob.file_identifiers.size).to eq(2)
      expect(reloaded.darwin_core.json_attributes['catalogNumber']).to eq('MVZ:Mamm:14524')
    end
  end

  it 'writes nothing when the document is refused' do
    expect { work.darwin_core_xml = Rails.root.join('spec/fixtures/files/dwc-two-records.xml').read }
      .to raise_error(Exceptions::DarwinCoreError)
    expect(darwin_core_file_set(work)).to be_nil
    expect(Metadata::DarwinCore.where(valkyrie_id: work.noid)).to be_empty
  end

  describe '#withdraw_darwin_core!' do
    before { work.darwin_core_xml = dwc_xml }

    it 'tombstones the FileSet, drops the access copy and keeps the bytes' do
      work.withdraw_darwin_core!(by: '000000004')

      reloaded = Work.find(work.id)
      expect(reloaded.darwin_core?).to be(false)
      expect(reloaded.metadata_formats).to eq([])
      expect(darwin_core_file_set(work).tombstoned).to be(true)
      expect(reloaded.darwin_core_blob.file.read).to eq(dwc_xml)
    end

    it 'does nothing when there is nothing to withdraw' do
      work.withdraw_darwin_core!(by: '000000004')
      expect { Work.find(work.id).withdraw_darwin_core!(by: '000000004') }
        .not_to(change { darwin_core_file_set(work).tombstoned_at })
    end

    it 'is undone by the next write, on the same Blob' do
      work.withdraw_darwin_core!(by: '000000004')
      Work.find(work.id).darwin_core_xml = dwc_xml

      reloaded = Work.find(work.id)
      expect(reloaded.darwin_core?).to be(true)
      expect(darwin_core_file_set(work).tombstoned).to be(false)
      expect(reloaded.darwin_core_blob.file_identifiers.size).to eq(2)
    end
  end
end
