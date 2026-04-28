# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Metadata::METS do
  it 'round-trips attr_json fields through the database' do
    record = described_class.new(valkyrie_id: 'noid-test')
    record.agent = 'Atlas'
    record.created_at_iso = '2026-04-28T00:00:00Z'
    record.structure_label = 'fileSet'
    record.files = [
      Metadata::Fields::FileEntry.new(id: 'blob-1', mime_type: 'image/tiff', use: 'preservation')
    ]
    record.save!

    reloaded = described_class.find(record.id)
    expect(reloaded.agent).to eq('Atlas')
    expect(reloaded.created_at_iso).to eq('2026-04-28T00:00:00Z')
    expect(reloaded.structure_label).to eq('fileSet')
    expect(reloaded.files.first.id).to eq('blob-1')
    expect(reloaded.files.first.mime_type).to eq('image/tiff')
    expect(reloaded.files.first.use).to eq('preservation')
  end
end
