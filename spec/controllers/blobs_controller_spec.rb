# frozen_string_literal: true

require 'rails_helper'

describe BlobsController, type: :controller do
  render_views

  after :each do
    Atlas.query.find_all_of_model(model: Blob).each { |b| Atlas.persister.delete(resource: b) }
  end

  let(:community) { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work) { WorkCreator.call(parent_id: collection.noid) }

  describe 'GET #show' do
    let(:blob) { BlobCreator.call(path: Rails.root.join('spec/fixtures/files/example.bin').to_s, work_id: work.noid, original_filename: 'example.bin') }

    context 'when the blob exists' do
      it 'returns the blob details' do
        get :show, params: { id: blob.noid }, as: :json
        expect(response).to have_http_status(:success)

        json_response = response.parsed_body
        expect(json_response['blob']['id']).to eq(blob.noid)
        expect(blob.parent).to be_a FileSet
        expect(blob.extension).to eq('bin')
      end
    end
  end

  describe 'GET #content' do
    let(:fixture_path) { Rails.root.join('spec/fixtures/files/example.bin') }
    let(:blob) do
      BlobCreator.call(path:              fixture_path.to_s,
                       work_id:           work.noid,
                       original_filename: 'example.bin')
    end

    context 'when the blob exists and has a file' do
      it 'streams the binary with attachment disposition and matching content type' do
        get :content, params: { id: blob.noid }

        expect(response).to have_http_status(:success)
        expect(response.headers['Content-Type']).to eq(blob.mime_type)
        expect(response.headers['Content-Disposition']).to include('attachment')
        expect(response.headers['Content-Disposition']).to include('example.bin')
        expect(response.body.bytesize).to eq(File.size(fixture_path))
        expect(response.body.b).to eq(File.binread(fixture_path))
      end
    end

    context 'when the blob does not exist' do
      it 'returns 404' do
        get :content, params: { id: 'bogus-noid' }
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'GET #index' do
    context 'when blobs exists' do
      it 'returns a paginated list of all blobs' do
        12.times do
          BlobCreator.call(path: Rails.root.join('spec/fixtures/files/example.png').to_s, work_id: work.noid, original_filename: 'example.png')
        end

        get :index, as: :json
        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        expect(json_response['blobs']).not_to be_empty
        # TODO: ensure pagination results are correct
      end
    end
  end

  describe 'POST #create' do
    it 'creates a Blob with provided work id as parent' do
      post :create, params: { work_id: work.noid, binary: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/example.png')) }, as: :json
      expect(response).to have_http_status(:success)
      # TODO: Test id is returned and resolves to resource
    end
  end

  describe 'PATCH #update' do
    let(:blob) { BlobCreator.call(path: Rails.root.join('spec/fixtures/files/example.png').to_s, work_id: work.noid, original_filename: 'example.png') }
    let(:replacement) { Rails.root.join('spec/fixtures/files/example.tif') }

    it 'updates a work with provided XML binary' do
      patch :update, params: { id: blob.noid, binary: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) }, as: :json
      expect(response).to have_http_status(:success)
      expect(Blob.find(blob.noid).versions).to eq(2)
    end

    it 'refreshes size and mime_type to the new revision, and keeps the deposited filename and label' do
      patch :update, params: { id: blob.noid, binary: Rack::Test::UploadedFile.new(replacement) }, as: :json
      expect(response).to have_http_status(:success)

      updated = Blob.find(blob.noid)
      expect(updated.size).to eq(File.size(replacement))
      expect(updated.mime_type).to eq('image/tiff')
      expect(updated.original_filename).to eq('example.png')
      expect(updated.label).to eq(blob.label)
    end

    # The replacing upload is usually a staged temp file, whose name tells Marcel
    # nothing: a CSV posted as upload.tmp detects as application/octet-stream.
    # The deposited filename is the hint that keeps a weak-magic format right.
    it 'hints mime detection with the deposited filename, not the upload name' do
      csv_path = Rails.root.join('spec/fixtures/files/example.csv')
      csv = BlobCreator.call(path: csv_path.to_s, work_id: work.noid, original_filename: 'data.csv')

      patch :update, params: {
        id:     csv.noid,
        binary: Rack::Test::UploadedFile.new(csv_path, 'application/octet-stream',
                                             original_filename: 'upload.tmp')
      }, as: :json

      expect(Blob.find(csv.noid).mime_type).to eq('text/csv')
    end

    it 'renders the refreshed size' do
      patch :update, params: { id: blob.noid, binary: Rack::Test::UploadedFile.new(replacement) }, as: :json

      expect(response.parsed_body.dig('blob', 'size')).to eq(File.size(replacement))
    end

    context 'when the blob does not exist' do
      it 'returns 404' do
        patch :update, params: { id: 'bogus-noid', binary: Rack::Test::UploadedFile.new(replacement) }, as: :json
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'POST #rollback' do
    let(:original) { Rails.root.join('spec/fixtures/files/example.png') }
    let(:replacement) { Rails.root.join('spec/fixtures/files/example.tif') }
    let(:blob) { BlobCreator.call(path: original.to_s, work_id: work.noid, original_filename: 'example.png') }

    it 'restores the reinstated revision size and mime_type' do
      patch :update, params: { id: blob.noid, binary: Rack::Test::UploadedFile.new(replacement) }, as: :json
      replaced = Blob.find(blob.noid)
      expect(replaced.size).to eq(File.size(replacement))

      seed_version = BinaryVersionHistory.descriptors(blob: replaced).last[:version_id]
      post :rollback, params: { id: blob.noid, version_id: seed_version }, as: :json
      expect(response).to have_http_status(:success)

      rolled_back = Blob.find(blob.noid)
      expect(rolled_back.size).to eq(File.size(original))
      expect(rolled_back.mime_type).to eq('image/png')
    end
  end

  describe 'DELETE #destroy' do
    let(:blob) { BlobCreator.call(path: Rails.root.join('spec/fixtures/files/example.png').to_s, work_id: work.noid, original_filename: 'example.png') }

    context 'when blob exists' do
      it 'destroys the blob' do
        delete :destroy, params: { id: blob.noid }, as: :json
        expect(response).to have_http_status(:success)
        expect(Blob.find(blob.noid)).to be_nil
      end

      it 'removes the orphan id from the parent FileSet member_ids and regenerates METS' do
        parent_id = blob.parent.id
        blob_id   = blob.id

        delete :destroy, params: { id: blob.noid }, as: :json

        parent = FileSet.find(parent_id)
        expect(parent.member_ids).not_to include(blob_id)

        file_ids = Nokogiri::XML(parent.mets_xml)
                           .xpath('//m:fileSec//m:file/@ID', m: METSBuilder::METS_NS)
                           .map(&:value)
        expect(file_ids).not_to include("f-#{blob.noid}")
      end
    end
  end
end
