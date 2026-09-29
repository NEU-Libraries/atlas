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

  describe 'a caption track language and label' do
    let(:caption) { Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/example.bin')) }

    it 'stores both on create and renders them' do
      post :create, params: { work_id: work.noid, binary: caption, language: 'es-MX', track_label: 'Español' }, as: :json

      expect(response.parsed_body['blob']).to include('language' => 'es-MX', 'track_label' => 'Español')
      expect(Blob.find(response.parsed_body.dig('blob', 'id')).graph_payload)
        .to include(language: 'es-MX', track_label: 'Español')
    end

    it 'refuses a malformed language before storing anything' do
      work
      expect { post :create, params: { work_id: work.noid, binary: caption, language: 'Spanish (Mexico)' }, as: :json }
        .not_to(change { Atlas.query.find_all_of_model(model: Blob).count })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq('invalid_language')
    end

    it 'refuses an over-long track label' do
      post :create, params: { work_id: work.noid, binary: caption, track_label: 'x' * 65 }, as: :json

      expect(response.parsed_body['error']).to eq('invalid_track_label')
    end

    context 'when replacing the bytes' do
      let(:blob) do
        BlobCreator.call(path: Rails.root.join('spec/fixtures/files/example.bin').to_s, work_id: work.noid,
                         original_filename: 'en.vtt', language: 'en', track_label: 'English')
      end

      it 'keeps a language the update does not mention' do
        patch :update, params: { id: blob.noid, binary: caption }, as: :json

        expect(Blob.find(blob.noid)).to have_attributes(language: 'en', track_label: 'English')
      end

      it 'changes the one it sends and clears one sent empty' do
        patch :update, params: { id: blob.noid, binary: caption, language: 'fr', track_label: '' }, as: :json

        expect(Blob.find(blob.noid)).to have_attributes(language: 'fr', track_label: nil)
      end

      it 'refuses a malformed language without appending a revision' do
        patch :update, params: { id: blob.noid, binary: caption, language: 'not a tag' }, as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(Blob.find(blob.noid).versions).to eq(1)
      end
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

  describe 'replacing a file with one of another type' do
    let(:docx) { Rails.root.join('spec/fixtures/files/example.docx') }
    let(:pdf)  { Rails.root.join('spec/fixtures/files/example.pdf') }
    let(:blob) { BlobCreator.call(path: docx.to_s, work_id: work.noid, original_filename: 'report.docx') }

    before do
      replacement = Rack::Test::UploadedFile.new(pdf)
      patch :update, params: { id: blob.noid, binary: replacement, original_filename: 'report.pdf' }, as: :json
      # A controller spec reuses one request object, so the PATCH's multipart
      # body would otherwise be re-parsed by the GET that follows.
      request.env.delete('CONTENT_TYPE')
      request.env.delete('RAW_POST_DATA')
    end

    it 'downloads the head under its new name and type' do
      get :content, params: { id: blob.noid }

      expect(response.headers['Content-Type']).to eq('application/pdf')
      expect(response.headers['Content-Disposition']).to include('report.pdf')
    end

    it 'lists each revision under its own name' do
      get :versions, params: { id: blob.noid }, as: :json

      expect(response.parsed_body['versions'].pluck('original_filename')).to eq(%w[report.pdf report.docx])
    end

    it 'downloads an earlier revision as what it was' do
      seed = BinaryVersionHistory.descriptors(blob: Blob.find(blob.noid)).last[:version_id]
      get :version_content, params: { id: blob.noid, version_id: seed }

      expect(response.headers['Content-Disposition']).to include('report.docx')
      expect(response.headers['Content-Type']).to include('wordprocessingml')
    end

    it "restores the earlier revision's name, type, label and classification on rollback" do
      seed = BinaryVersionHistory.descriptors(blob: Blob.find(blob.noid)).last[:version_id]
      post :rollback, params: { id: blob.noid, version_id: seed }, as: :json

      rolled_back = Blob.find(blob.noid)
      expect(rolled_back).to have_attributes(original_filename: 'report.docx', label: 'msword')
      expect(rolled_back.mime_type).to include('wordprocessingml')
      expect(FileSet.find(rolled_back.parent.id).type).to eq(blob.parent.type)
    end

    it 'records the new name on the replace event' do
      event = AuditEvent.where(action: 'replace_file').last
      expect(event.payload).to include('filename' => 'report.pdf')
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
