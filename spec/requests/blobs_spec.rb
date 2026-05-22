# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Files (Blobs)', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:fixture)    { Rails.root.join('spec/fixtures/files/example.bin') }
  let!(:guest) do
    User.find_by_role(:guest) ||
      User.create!(email: 'guest@example.com', password: SecureRandom.hex(16), role: :guest)
  end

  after { Atlas.persister.wipe! }

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
      description <<~DESC
        Uploads a binary as a Blob attached to a Work.

        Idempotent on the optional `Idempotency-Key` header: a repeat
        request from the same caller with the same key returns the
        originally-created Blob without re-uploading. 410 + tombstone
        payload if the underlying Blob has been tombstoned.
      DESC
      parameter name: :work_id,           in: :formData, required: true
      parameter name: :original_filename, in: :formData, required: false
      parameter name: :binary,            in: :formData, required: true
      parameter name: :'Idempotency-Key', in: :header, type: :string, required: false,
                description: 'Client-supplied UUID; repeats return the existing resource.'
      multipart_request_body(
        {
          work_id:           { type: :string, description: 'NOID of the parent Work' },
          original_filename: { type: :string },
          binary:            { type: :string, format: :binary, description: 'File bytes to upload' }
        },
        required: %i[work_id binary]
      )

      response '200', 'file uploaded' do
        let(:work_id)           { work.noid }
        let(:original_filename) { 'example.bin' }
        let(:binary)            { Rack::Test::UploadedFile.new(fixture) }
        let(:'Idempotency-Key') { nil }
        schema '$ref' => '#/components/schemas/Blob'
        run_test!
      end

      response '200', 'idempotent replay returns existing blob' do
        let(:work_id)           { work.noid }
        let(:original_filename) { 'example.bin' }
        let(:binary)            { Rack::Test::UploadedFile.new(fixture) }
        let(:idempotency_key)   { SecureRandom.uuid }
        let(:'Idempotency-Key') { idempotency_key }
        let!(:existing) do
          b = BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s)
          IdempotencyKey.create!(user: User.find_by_nuid('000000004'), key: idempotency_key,
                                 resource_type: 'Blob', resource_noid: b.noid)
          b
        end
        schema '$ref' => '#/components/schemas/Blob'
        run_test! do |response|
          expect(JSON.parse(response.body).dig('blob', 'id')).to eq(existing.noid)
        end
      end

      response '410', 'idempotent replay on a tombstoned blob' do
        let(:work_id)           { work.noid }
        let(:original_filename) { 'example.bin' }
        let(:binary)            { Rack::Test::UploadedFile.new(fixture) }
        let(:idempotency_key)   { SecureRandom.uuid }
        let(:'Idempotency-Key') { idempotency_key }
        let!(:existing) do
          b = BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s)
          b.tombstoned = true
          b = Atlas.persister.save(resource: b)
          IdempotencyKey.create!(user: User.find_by_nuid('000000004'), key: idempotency_key,
                                 resource_type: 'Blob', resource_noid: b.noid)
          b
        end
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

      response '410', 'file tombstoned' do
        let(:blob) do
          b = BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s)
          b.tombstoned = true
          Atlas.persister.save(resource: b)
        end
        let(:id) { blob.noid }
        schema '$ref' => '#/components/schemas/Blob'
        run_test!
      end
    end

    patch 'Append a new revision to a file' do
      tags 'Files'
      consumes 'multipart/form-data'
      produces 'application/json'
      description 'Uber-basic versioning: posts a new binary, appends its file identifier to the Blob.'
      parameter name: :binary, in: :formData, required: true
      multipart_request_body(
        { binary: { type: :string, format: :binary, description: 'New revision bytes' } },
        required: %i[binary]
      )

      response '200', 'revision appended' do
        let(:blob)   { BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s) }
        let(:id)     { blob.noid }
        let(:binary) { Rack::Test::UploadedFile.new(fixture) }
        schema '$ref' => '#/components/schemas/Blob'
        run_test!
      end
    end

    delete 'Destroy a file' do
      tags 'Files'

      response '204', 'file destroyed' do
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
