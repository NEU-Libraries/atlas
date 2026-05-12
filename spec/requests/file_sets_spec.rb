# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'FileSets', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  after { Atlas.persister.wipe! }

  path '/file_sets' do
    get 'List file sets' do
      tags 'FileSets'
      produces 'application/json'

      response '200', 'file sets listed' do
        before { FileSetCreator.call(work_id: work.noid, classification: Classification.generic) }
        schema '$ref' => '#/components/schemas/FileSetsIndex'
        run_test!
      end
    end

    post 'Create a file set' do
      tags 'FileSets'
      consumes 'application/json'
      produces 'application/json'
      description 'Creates a FileSet under a Work, classified by name (e.g. `generic`).'
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          work_id: { type: :string, description: 'NOID of the parent Work' },
          classification: { type: :string, description: 'Classification name, e.g. generic' }
        },
        required: %w[work_id classification]
      }

      response '200', 'file set created' do
        let(:body) { { work_id: work.noid, classification: 'generic' } }
        schema '$ref' => '#/components/schemas/FileSet'
        run_test!
      end
    end
  end

  path '/file_sets/{id}' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the FileSet'

    get 'Retrieve a file set' do
      tags 'FileSets'
      produces 'application/json'

      response '200', 'file set found' do
        let(:file_set) { FileSetCreator.call(work_id: work.noid, classification: Classification.generic) }
        let(:id)       { file_set.noid }
        schema '$ref' => '#/components/schemas/FileSet'
        run_test!
      end

      response '410', 'file set tombstoned' do
        let(:file_set) do
          fs = FileSetCreator.call(work_id: work.noid, classification: Classification.generic)
          fs.tombstoned = true
          Atlas.persister.save(resource: fs)
        end
        let(:id) { file_set.noid }
        schema '$ref' => '#/components/schemas/FileSet'
        run_test!
      end
    end

    patch 'Append binary content to a file set' do
      tags 'FileSets'
      consumes 'multipart/form-data'
      produces 'application/json'
      description 'Naive first implementation: posts binary content and appends it as a Blob to the existing FileSet.'
      parameter name: :binary, in: :formData, required: true
      multipart_request_body(
        { binary: { type: :string, format: :binary, description: 'Binary file to attach' } },
        required: %i[binary]
      )

      response '200', 'binary attached' do
        let(:file_set) { FileSetCreator.call(work_id: work.noid, classification: Classification.generic) }
        let(:id)       { file_set.noid }
        let(:binary)   { Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/example.bin')) }
        schema '$ref' => '#/components/schemas/FileSet'
        run_test!
      end
    end

    delete 'Destroy a file set' do
      tags 'FileSets'

      response '204', 'file set destroyed' do
        let(:file_set) { FileSetCreator.call(work_id: work.noid, classification: Classification.generic) }
        let(:id)       { file_set.noid }
        run_test!
      end
    end
  end

  path '/file_sets/{id}/mets' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the FileSet'

    get 'Retrieve METS metadata for a file set' do
      tags 'FileSets'
      produces 'application/json'
      description 'Returns the JSON projection of the FileSet structural (METS) metadata.'

      response '200', 'mets returned' do
        let(:file_set) { FileSetCreator.call(work_id: work.noid, classification: Classification.generic) }
        let(:id)       { file_set.noid }
        run_test!
      end
    end
  end
end
