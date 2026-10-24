# frozen_string_literal: true

require 'rails_helper'

# What the API answers for a Work with a part missing. Each case is one the
# health probe found answering 500; docs/work-health.md has the matrix.
RSpec.describe 'A damaged Work', type: :request do
  let(:collection) { CollectionCreator.call(parent_id: CommunityCreator.call.noid) }
  let(:mods_fixture) { Rails.root.join('spec/fixtures/files/work-mods.xml') }
  let(:work) { WorkCreator.call(parent_id: collection.noid, mods_xml: mods_fixture.read) }
  let(:blob) do
    source = Rails.root.join('tmp', "damaged-#{SecureRandom.hex(4)}.png")
    FileUtils.cp(Rails.root.join('spec/fixtures/files/example.png'), source)
    BlobCreator.call(path: source.to_s, work_id: work.noid, original_filename: 'example.png')
  end

  def object_dir(key)
    Valkyrie.config.storage_adapter.storage_roots.values.first.object_root_for(key)
  end

  def solr_docs(resource)
    Atlas.index_adapter.connection.get('select', params: { q: %(id:"#{resource.id}") }).dig('response', 'numFound')
  end

  describe 'with its MODS XML gone from storage' do
    before { FileUtils.rm_rf(object_dir(work.mods_blob.noid)) }

    it 'answers 404 for the XML' do
      get "/works/#{work.noid}/mods.xml"

      expect(response).to have_http_status(:not_found)
    end

    it 'can still be reindexed' do
      post "/resources/#{work.noid}/reindex"

      expect(response).to have_http_status(:no_content)
    end

    it 'can be repaired by a MODS PUT' do
      put "/resources/#{work.noid}/mods", params: { binary: Rack::Test::UploadedFile.new(mods_fixture) }
      get "/works/#{work.noid}/mods.xml"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("What's New")
    end
  end

  it 'gets its Solr document back from a reindex' do
    Atlas.index_adapter.connection.delete_by_query(%(id:"#{work.id}"))
    Atlas.index_adapter.connection.commit

    post "/resources/#{work.noid}/reindex"

    expect(response).to have_http_status(:no_content)
    expect(solr_docs(work)).to eq(1)
  end

  it 'recreates a missing descriptive FileSet on a MODS PUT' do
    descriptive = work.children.grep(FileSet).find { |fs| fs.type == Classification.descriptive_metadata.name }
    Atlas.persister.delete(resource: descriptive)

    put "/resources/#{work.noid}/mods", params: { binary: Rack::Test::UploadedFile.new(mods_fixture) }

    expect(response).to have_http_status(:ok)
    expect(Work.find(work.noid)).to be_mods_writable
    get "/works/#{work.noid}/mods.xml"
    expect(response.body).to include("What's New")
  end

  describe 'with a Blob saved without its MIME type or filename' do
    before do
      Atlas.persister.save(resource: Blob.find(blob.noid).tap do |b|
        b.mime_type = nil
        b.original_filename = nil
      end)
    end

    it 'serves the bytes, typed from the bytes' do
      get "/files/#{blob.noid}/content"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('image/png')
      expect(response.headers['Content-Disposition']).to include('attachment')
    end

    it 'serves a byte range the same way' do
      get "/files/#{blob.noid}/content", headers: { 'Range' => 'bytes=0-9' }

      expect(response).to have_http_status(:partial_content)
      expect(response.media_type).to eq('image/png')
    end
  end
end
