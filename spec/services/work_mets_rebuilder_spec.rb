# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WorkMETSRebuilder do
  include ActiveSupport::Testing::TimeHelpers

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

  # The lock keeps rebuilds in other sessions out, so this stands in for any
  # other writer: a nested rebuild, which the re-entrant lock lets through,
  # saves the METS Blob between this rebuild's read of it and its own save.
  describe 'when a concurrent rebuild wins the METS Blob save' do
    before do
      page(1)
      described_class.call(work: work)
      page(2)
      allow(StaleRetry).to receive(:pause)
    end

    def race_once
      raced = false
      allow(Atlas.persister).to receive(:save).and_wrap_original do |original, resource:, **rest|
        if !raced && resource.is_a?(Blob) && resource.persisted? && resource.use == Role.structural_metadata.name
          raced = true
          described_class.call(work: work)
        end
        original.call(resource: resource, **rest)
      end
    end

    it 'reloads, finds the winner already wrote the same XML, and adds nothing of its own' do
      race_once
      versions_before = Work.find(work.noid).mets_blob.file_identifiers.length

      expect { described_class.call(work: work) }.not_to raise_error

      expect(page_divs(work_mets_doc).length).to eq(2)
      expect(Work.find(work.noid).mets_blob.file_identifiers.length).to eq(versions_before + 1)
    end

    it 'gives up after the retry budget and re-raises' do
      allow(Atlas.persister).to receive(:save).and_wrap_original do |original, resource:, **rest|
        raise Valkyrie::Persistence::StaleObjectError if resource.is_a?(Blob) && resource.persisted?

        original.call(resource: resource, **rest)
      end

      expect { described_class.call(work: work) }.to raise_error(Valkyrie::Persistence::StaleObjectError)
    end
  end

  it 'projects the structMap into Metadata::METS pages' do
    fs = page(1)
    described_class.call(work: work)

    record = Metadata::METS.find_by(valkyrie_id: work.noid)
    expect(record.pages.map(&:noid)).to eq([fs.noid])
    expect(record.pages.map(&:order)).to eq([1])
    expect(record.pages.map(&:label)).to eq([nil])
  end

  def m(xpath, doc = work_mets_doc)
    doc.xpath(xpath, 'm' => METSBuilder::METS_NS, 'xlink' => METSBuilder::XLINK_NS)
  end

  describe 'the page rule' do
    it 'gives an all-image Work a physical map of pages, with no LABEL' do
      page(1)
      page(2)
      described_class.call(work: work)

      expect(m('//m:structMap/@TYPE').map(&:value)).to eq(%w[physical])
      expect(page_divs(work_mets_doc).length).to eq(2)
      expect(page_divs(work_mets_doc).pluck('LABEL')).to eq([nil, nil])
    end

    it 'gives a Work with any non-image file a logical map of files' do
      page(1)
      FileSetCreator.call(work_id: work.noid, classification: Classification.text, position: 2)
      described_class.call(work: work)

      expect(m('//m:structMap/@TYPE').map(&:value)).to eq(%w[logical])
      expect(page_divs(work_mets_doc)).to be_empty
      expect(m('//m:structMap/m:div/m:div').map { |d| [d['TYPE'], d['ORDER']] }).to eq([%w[file 1], %w[file 2]])
      expect(Metadata::METS.find_by(valkyrie_id: work.noid).pages).to eq([])
    end

    it 'gives a Work with no content a logical map' do
      described_class.call(work: work)

      expect(m('//m:structMap/@TYPE').map(&:value)).to eq(%w[logical])
    end
  end

  it 'links the MODS through a dmdSec that the Work div names' do
    page(1)
    described_class.call(work: work)

    mdref = m('//m:dmdSec/m:mdRef').first
    expect(mdref['MDTYPE']).to eq('MODS')
    expect(mdref['LOCTYPE']).to eq('URN')
    expect(mdref['xlink:href']).to eq("urn:neu-drs:#{Work.find(work.noid).mods_blob.noid}")
    expect(m('//m:structMap/m:div/@DMDID').map(&:value)).to eq([m('//m:dmdSec/@ID').first.value])
  end

  it 'moves LASTMODDATE only when the structure changes' do
    page(1)
    described_class.call(work: work)
    stamped = m('//m:metsHdr/@LASTMODDATE').first.value

    travel 1.minute do
      described_class.call(work: work)
      expect(m('//m:metsHdr/@LASTMODDATE').first.value).to eq(stamped)

      page(2)
      described_class.call(work: work)
      expect(m('//m:metsHdr/@LASTMODDATE').first.value).not_to eq(stamped)
    end
  end

  it 'writes METS that validates against the METS schema, in both shapes' do
    page(1)
    described_class.call(work: work)
    expect_valid_mets(Work.find(work.noid).mets_xml)

    FileSetCreator.call(work_id: work.noid, classification: Classification.text, position: 2)
    described_class.call(work: work)
    expect_valid_mets(Work.find(work.noid).mets_xml)
  end
end
