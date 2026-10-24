# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BlobCreator do
  let(:collection) { CollectionCreator.call(parent_id: CommunityCreator.call.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  # An upload arrives as a Rack tempfile, so its path names nothing a reader
  # of the storage could recognise.
  def upload(name)
    source = Rails.root.join('tmp', name)
    FileUtils.cp(Rails.root.join('spec/fixtures/files/example.pdf'), source)
    source.to_s
  end

  it 'stores the binary under the deposited filename, not the temporary one' do
    blob = described_class.call(path: upload("RackMultipart-#{SecureRandom.hex(4)}.pdf"),
                                work_id: work.noid, original_filename: 'Thesis Final.pdf')

    expect(blob.file_identifiers.last.to_s).to end_with('/Thesis Final.pdf')
  end

  it 'falls back to the source basename when no filename is given' do
    name = "unnamed-#{SecureRandom.hex(4)}.pdf"
    blob = described_class.call(path: upload(name), work_id: work.noid)

    expect(blob.file_identifiers.last.to_s).to end_with("/#{name}")
  end
end
