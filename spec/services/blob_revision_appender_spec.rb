# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BlobRevisionAppender do
  after { Atlas.persister.wipe! }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  def fixture(name) = Rails.root.join('spec/fixtures/files', name).to_s

  def deposit(name, **)
    BlobCreator.call(path: fixture(name), work_id: work.noid, original_filename: name, **)
  end

  def replace(blob, with:, name:)
    described_class.call(blob: blob, source_path: fixture(with), name: name).first
  end

  describe 'a primary replaced with a file of another type' do
    let(:blob) { deposit('example.docx') }
    let!(:replaced) { replace(blob, with: 'example.pdf', name: 'report.pdf') }

    it 'takes the new name, MIME type and label' do
      expect(replaced).to have_attributes(original_filename: 'report.pdf', mime_type: 'application/pdf',
                                          label: Label.pdf.symbol.to_s)
      expect(replaced.filename).to end_with('.pdf')
    end

    it 'keeps the name of every earlier revision' do
      seed, head = replaced.file_identifiers
      expect(replaced.filename_for(seed)).to eq('example.docx')
      expect(replaced.filename_for(head)).to eq('report.pdf')
    end

    it 'records the names in the envelope, keyed by OCFL version' do
      expect(replaced.graph_payload[:revision_filenames].values).to eq(%w[example.docx report.pdf])
    end

    it "names the revision's OCFL logical path after the file" do
      expect(replaced.latest_revision.to_s).to end_with('/report.pdf')
    end
  end

  it "moves the FileSet's classification along with a primary that changes type" do
    blob = deposit('example.png')
    expect(blob.parent.type).to eq(Classification.image.name)

    replace(blob, with: 'example.pdf', name: 'scan.pdf')

    expect(FileSet.find(blob.parent.id).type).to eq(Classification.text.name)
  end

  it 'keeps a derivative label, which names its tier rather than its type' do
    blob = deposit('example.png', use: Role.small_image.name)
    blob.label = Label.image_small.symbol
    blob = Atlas.persister.save(resource: blob)

    expect(replace(blob, with: 'example.tif', name: 'small.tif').label).to eq('image_small')
  end

  it 'pins a Blob deposited before names were recorded to its own name' do
    blob = deposit('example.docx')
    blob.revision_filenames = nil
    blob = Atlas.persister.save(resource: blob)

    replaced = replace(blob, with: 'example.pdf', name: 'report.pdf')

    expect(replaced.filename_for(replaced.file_identifiers.first)).to eq('example.docx')
  end

  it "points the FileSet's METS at the new revision" do
    blob = deposit('example.png')
    replaced = replace(blob, with: 'example.tif', name: 'example.tif')

    expect(FileSet.find(blob.parent.id).mets_xml).to include(replaced.latest_revision.to_s)
  end
end
