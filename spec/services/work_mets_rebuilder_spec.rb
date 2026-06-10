# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WorkMETSRebuilder do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  def page(position = nil)
    FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: position)
  end

  def work_mets_doc
    Nokogiri::XML(Work.find(work.noid).mets_xml, &:noblanks)
  end

  def page_divs(doc)
    doc.xpath('//m:structMap[@TYPE="physical"]//m:div[@TYPE="page"]', m: METSBuilder::METS_NS)
  end

  it 'builds a physical structMap with page divs ordered by position' do
    page(2)
    page(1)
    described_class.call(work: work)

    divs = page_divs(work_mets_doc)
    expect(divs.pluck('ORDER')).to eq(%w[1 2])
  end

  it 'points each page div at its FileSet via mptr (urn:neu-drs NOID)' do
    fs = page(1)
    described_class.call(work: work)

    hrefs = work_mets_doc.xpath('//m:mptr/@xlink:href',
                                'm' => METSBuilder::METS_NS, 'xlink' => METSBuilder::XLINK_NS).map(&:value)
    expect(hrefs).to eq(["urn:neu-drs:#{fs.noid}"])
  end

  it 'omits ORDER for unordered FileSets while keeping them in document order, last' do
    page(nil)
    page(1)
    described_class.call(work: work)

    divs = page_divs(work_mets_doc)
    expect(divs.pluck('ORDER')).to eq(['1', nil])
  end

  it 'creates the structural-metadata FileSet lazily on first build' do
    expect(work.children.map(&:type)).not_to include(Classification.structural_metadata.name)

    described_class.call(work: work)

    expect(Work.find(work.noid).children.map(&:type)).to include(Classification.structural_metadata.name)
  end

  it 'excludes metadata and derivative FileSets from the structMap' do
    page(1)
    DelegateCreator.call(resource_id: work.id, use: Role.service_file.name,
                         uri: 'https://iiif.example/x.jpg')
    described_class.call(work: work)

    expect(page_divs(work_mets_doc).length).to eq(1)
  end

  it 'is idempotent — a rebuild with no membership change writes nothing' do
    page(1)
    described_class.call(work: work)
    before_versions = Work.find(work.noid).mets_blob.file_identifiers.length

    described_class.call(work: work)

    expect(Work.find(work.noid).mets_blob.file_identifiers.length).to eq(before_versions)
  end

  it 'preserves CREATEDATE across rebuilds' do
    page(1)
    described_class.call(work: work)
    created = work_mets_doc.at_xpath('//m:metsHdr/@CREATEDATE', m: METSBuilder::METS_NS).value

    page(2)
    described_class.call(work: work)

    expect(work_mets_doc.at_xpath('//m:metsHdr/@CREATEDATE', m: METSBuilder::METS_NS).value).to eq(created)
  end

  it 'projects the structMap into Metadata::METS pages' do
    fs = page(1)
    described_class.call(work: work)

    record = Metadata::METS.find_by(valkyrie_id: work.noid)
    expect(record.pages.map(&:noid)).to eq([fs.noid])
    expect(record.pages.map(&:order)).to eq([1])
    expect(record.pages.map(&:label)).to eq([Classification.image.name])
  end
end
