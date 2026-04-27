# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Files (Blobs)', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:fixture)    { Rails.root.join('spec/fixtures/files/example.bin') }

  after { Valkyrie.config.metadata_adapter.persister.wipe! }

  path '/files' do
    get 'List files' do
      tags 'Files'
      produces 'application/json'

      response '200', 'files listed' do
        schema '$ref' => '#/components/schemas/BlobsIndex'
        run_test!
      end
    end

    post 'Upload a file' do
      tags 'Files'
      consumes 'multipart/form-data'
      produces 'application/json'
      description 'Uploads a binary as a Blob attached to a Work.'
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          work_id:           { type: :string, description: 'NOID of the parent Work' },
          original_filename: { type: :string },
          binary:            { type: :string, format: :binary, description: 'File bytes to upload' }
        },
        required: %w[work_id binary]
      }

      response '200', 'file uploaded' do
        let(:body) {
          {
            work_id:           work.noid,
            original_filename: 'example.bin',
            binary:            Rack::Test::UploadedFile.new(fixture)
          }
        }
        schema '$ref' => '#/components/schemas/Blob'
        run_test!
      end
    end
  end

  path '/files/{id}' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Blob'

    get 'Retrieve file metadata' do
      tags 'Files'
      produces 'application/json'

      response '200', 'file found' do
        let(:blob) { BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s) }
        let(:id)   { blob.noid }
        schema '$ref' => '#/components/schemas/Blob'
        run_test!
      end
    end

    patch 'Append a new revision to a file' do
      tags 'Files'
      consumes 'multipart/form-data'
      produces 'application/json'
      description 'Uber-basic versioning: posts a new binary, appends its file identifier to the Blob.'
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          binary: { type: :string, format: :binary, description: 'New revision bytes' }
        },
        required: %w[binary]
      }

      response '200', 'revision appended' do
        let(:blob) { BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s) }
        let(:id)   { blob.noid }
        let(:body) { { binary: Rack::Test::UploadedFile.new(fixture) } }
        schema '$ref' => '#/components/schemas/Blob'
        run_test!
      end
    end

    delete 'Destroy a file' do
      tags 'Files'

      response '200', 'file destroyed' do
        let(:blob) { BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s) }
        let(:id)   { blob.noid }
        run_test!
      end
    end
  end

  path '/files/{id}/content' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Blob'

    get 'Stream file content bytes' do
      tags 'Files'
      produces 'application/octet-stream'
      description 'Streams the underlying bytes via send_file with attachment disposition. Memory-safe for large files.'

      response '200', 'content streamed' do
        let(:blob) { BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s) }
        let(:id)   { blob.noid }
        run_test!
      end
    end
  end
end
