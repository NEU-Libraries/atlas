# frozen_string_literal: true

require 'rails_helper'

# `updated_at` on a record is a change marker a client keys on, so what moves
# it is part of the contract: an edit to the record moves it, and a file added
# to a Work moves only the file's own record. See docs/openapi.md.
RSpec.describe 'A record\'s updated_at', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  def updated_at(noid)
    get "/works/#{noid}"
    Time.iso8601(response.parsed_body.dig('work', 'updated_at'))
  end

  it 'moves when the Work\'s MODS is replaced' do
    before = updated_at(work.noid)
    travel 1.minute do
      put "/resources/#{work.noid}/mods",
          params: { binary: Rack::Test::UploadedFile.new(file_fixture('work-mods.xml')) }
    end

    expect(response).to have_http_status(:ok)
    expect(updated_at(work.noid)).to be > before
  end

  it 'stays put when a file is added to the Work' do
    before = updated_at(work.noid)
    travel 1.minute do
      Tempfile.create(['added', '.txt']) do |file|
        file.write('bytes')
        file.flush
        BlobCreator.call(path: file.path, work_id: work.noid, original_filename: 'added.txt')
      end
    end

    expect(updated_at(work.noid)).to eq(before)
  end
end
