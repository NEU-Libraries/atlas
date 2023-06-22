# frozen_string_literal: true

require 'rails_helper'

describe BlobsController, type: :controller do
  render_views

  after :each do
    Atlas.query.find_all_of_model(model: Blob).each do |b| Atlas.persister.delete(resource: b) end
  end

  let(:community) { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work) { WorkCreator.call(parent_id: collection.noid) }

  describe 'GET #show' do
    let(:blob) { BlobCreator.call(path: Rails.root.join('spec/fixtures/files/100KB.bin').to_s, work_id: work.noid) }

    context 'when the blob exists' do
      it 'returns the blob details' do
        get :show, params: { id: blob.noid }, as: :json
        expect(response).to have_http_status(:success)

        json_response = response.parsed_body
        expect(json_response['blob']['id']).to eq(blob.noid)
        expect(blob.parent).to be_a FileSet
      end
    end
  end

  describe 'GET #index' do
    context 'when blobs exists' do
      it 'returns a paginated list of all blobs' do
        12.times do
          BlobCreator.call(path: Rails.root.join('spec/fixtures/files/image.png').to_s, work_id: work.noid)
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
      post :create, params: { work_id: work.noid, binary: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/image.png')) }
      expect(response).to have_http_status(:success)
      # TODO: Test id is returned and resolves to resource
    end
  end

  describe 'PATCH #update' do
    let(:blob) { BlobCreator.call(path: Rails.root.join('spec/fixtures/files/image.png').to_s, work_id: work.noid) }

    it 'updates a work with provided XML binary' do
      patch :update, params: { id: blob.noid, binary: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) }
      expect(response).to have_http_status(:success)
      expect(blob.versions).to eq(2)
    end
  end

  describe 'DELETE #destroy' do
    let(:blob) { BlobCreator.call(path: Rails.root.join('spec/fixtures/files/image.png').to_s, work_id: work.noid) }

    context 'when blob exists' do
      it 'destroys the blob' do
        expect(Blob.find(blob.noid)).to eq(blob)
        delete :destroy, params: { id: blob.noid }, as: :json
        expect(response).to have_http_status(:success)
        expect(Blob.find(blob.noid)).to be_nil
      end
    end
  end
end
