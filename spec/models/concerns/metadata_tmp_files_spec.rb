# frozen_string_literal: true

require 'rails_helper'

# Every metadata write stages its XML in a temp file. The OCFL adapter moves new
# bytes into the object but skips bytes it already holds, so a write of
# unchanged XML is the case that leaves a file behind unless the writer cleans
# up. See FileHelper#with_tmp_file.
RSpec.describe 'Metadata writes leave no temp file behind' do
  after { Atlas.persister.wipe! }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  # The path of every file a write hands to storage, however it was staged.
  def staged_paths
    paths = []
    allow(Valkyrie.config.storage_adapter).to receive(:upload).and_wrap_original do |original, file:, **rest|
      paths << file.path
      original.call(file: file, **rest)
    end
    yield
    paths
  end

  def written_twice(resource, &write)
    staged_paths { 2.times { write.call(resource) } }
  end

  it 'removes the MODS file, new bytes and unchanged alike' do
    xml = Work.find(work.noid).mods_xml
    paths = written_twice(Work.find(work.noid)) { |w| w.mods_xml = xml }

    expect(paths.size).to eq(2)
    expect(paths.select { |path| File.exist?(path) }).to be_empty
  end

  it 'removes the METS file' do
    paths = written_twice(Work.find(work.noid)) { |w| WorkMETSRebuilder.call(work: w) }

    expect(paths).not_to be_empty
    expect(paths.select { |path| File.exist?(path) }).to be_empty
  end

  it 'removes the Darwin Core file' do
    dwc = Rails.root.join('spec/fixtures/files/dwc.xml').read
    paths = written_twice(Work.find(work.noid)) { |w| w.darwin_core_xml = dwc }

    expect(paths.size).to eq(2)
    expect(paths.select { |path| File.exist?(path) }).to be_empty
  end
end
