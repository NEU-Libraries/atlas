# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'FileSets', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let!(:guest) do
    User.find_by(role: :guest) ||
      User.create!(email: 'guest@example.com', password: SecureRandom.hex(16), role: :guest)
  end

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
      description <<~DESC
        Creates a FileSet under a Work, classified by name (e.g. `generic`).

        Idempotent on the optional `Idempotency-Key` header: a repeat
        request from the same caller with the same key returns the
        originally-created FileSet. 410 + tombstone payload if the
        underlying FileSet has been tombstoned in the interim.
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          work_id:        { type: :string, description: 'NOID of the parent Work' },
          classification: { type: :string, description: 'Classification name, e.g. generic' },
          position:       { type:        :integer,
                            description: 'Optional 1-based page order within the parent Work (multipage Works). Omit for unordered FileSets.' }
        },
        required:   %w[work_id classification]
      }
      parameter name: :'Idempotency-Key', in: :header, type: :string, required: false,
                description: 'Client-supplied UUID; repeats return the existing resource.'

      response '200', 'file set created' do
        let(:body) { { work_id: work.noid, classification: 'generic' } }
        let(:'Idempotency-Key') { nil }
        schema '$ref' => '#/components/schemas/FileSet'
        run_test! do |response|
          expect(JSON.parse(response.body).dig('file_set', 'position')).to be_nil
        end
      end

      response '200', 'file set created with a page position' do
        let(:body) { { work_id: work.noid, classification: 'image', position: 2 } }
        let(:'Idempotency-Key') { nil }
        schema '$ref' => '#/components/schemas/FileSet'
        run_test! do |response|
          expect(JSON.parse(response.body).dig('file_set', 'position')).to eq(2)
        end
      end

      response '200', 'idempotent replay returns existing file set' do
        let(:body) { { work_id: work.noid, classification: 'generic' } }
        let(:idempotency_key) { SecureRandom.uuid }
        let(:'Idempotency-Key') { idempotency_key }
        let!(:existing) do
          fs = FileSetCreator.call(work_id: work.noid, classification: Classification.generic)
          IdempotencyKey.create!(user: User.find_by(nuid: '000000004'), key: idempotency_key,
                                 resource_type: 'FileSet', resource_noid: fs.noid)
          fs
        end
        schema '$ref' => '#/components/schemas/FileSet'
        run_test! do |response|
          expect(JSON.parse(response.body).dig('file_set', 'id')).to eq(existing.noid)
        end
      end

      response '410', 'idempotent replay on a tombstoned file set' do
        let(:body) { { work_id: work.noid, classification: 'generic' } }
        let(:idempotency_key) { SecureRandom.uuid }
        let(:'Idempotency-Key') { idempotency_key }
        let!(:existing) do
          fs = FileSetCreator.call(work_id: work.noid, classification: Classification.generic)
          fs.tombstoned = true
          fs = Atlas.persister.save(resource: fs)
          IdempotencyKey.create!(user: User.find_by(nuid: '000000004'), key: idempotency_key,
                                 resource_type: 'FileSet', resource_noid: fs.noid)
          fs
        end
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

  path '/file_sets/{id}/iiif_service' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the FileSet'

    patch 'Attach the IIIF image-service Delegate URI to a file set' do
      tags 'FileSets'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Upserts the per-page IIIF image-service pointer (`service_file`
        Delegate role) on the FileSet — the Cantaloupe base URI for the
        page's JP2, from which a viewer derives any size on demand via
        `info.json`. The Delegate nests in a `:derivative` FileSet under
        the page and surfaces in `GET /works/{id}/file_sets` for IIIF
        manifest assembly.

        Sibling of the Work-level `/thumbnails` and `/image_derivatives`
        endpoints, dispatched through DelegateUpdater: re-PATCHing never
        mints a duplicate Delegate, and a blank or missing `uri` is a
        no-op.
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        required:   %w[uri],
        properties: {
          uri: { type: :string, description: "IIIF image-service base URI for the page's JP2" }
        }
      }

      response '200', 'service pointer attached and readable through the page listing' do
        let(:file_set) { FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: 1) }
        let(:id)       { file_set.noid }
        let(:body)     { { uri: 'https://iiif.example/iiif/3/abc.jp2' } }
        schema '$ref' => '#/components/schemas/FileSet'
        run_test! do
          reloaded = FileSet.find(file_set.noid)
          deriv_fs = reloaded.children.find { |c| c.is_a?(FileSet) && c.type == Classification.derivative.name }
          members  = Atlas.query.find_members(resource: deriv_fs).to_a.select { |m| m.is_a?(Delegate) }
          expect(members.map { |m| [m.use, m.uri] })
            .to eq([[Role.service_file.name, 'https://iiif.example/iiif/3/abc.jp2']])

          get "/works/#{work.noid}/file_sets"
          pages = response.parsed_body
          expect(pages.first['assets'].pluck('uri')).to include('https://iiif.example/iiif/3/abc.jp2')
        end
      end

      response '200', 're-PATCHing upserts in place — one Delegate, latest URI' do
        let(:file_set) { FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: 1) }
        let(:id)       { file_set.noid }
        let(:body)     { { uri: 'https://iiif.example/iiif/3/abc.jp2?v2' } }
        before do
          patch "/file_sets/#{file_set.noid}/iiif_service",
                params:  { uri: 'https://iiif.example/iiif/3/abc.jp2' }.to_json,
                headers: { 'CONTENT_TYPE' => 'application/json' }
        end
        schema '$ref' => '#/components/schemas/FileSet'
        run_test! do
          reloaded = FileSet.find(file_set.noid)
          deriv_fs = reloaded.children.find { |c| c.is_a?(FileSet) && c.type == Classification.derivative.name }
          members  = Atlas.query.find_members(resource: deriv_fs).to_a.select { |m| m.is_a?(Delegate) }
          expect(members.size).to eq(1)
          expect(members.first.uri).to eq('https://iiif.example/iiif/3/abc.jp2?v2')
        end
      end

      response '404', 'unknown file set' do
        let(:id)   { 'doesnotexist' }
        let(:body) { { uri: 'https://iiif.example/iiif/3/abc.jp2' } }
        run_test!
      end

      response '409', 'optimistic-lock conflict survived the internal retry budget' do
        let(:file_set) { FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: 1) }
        let(:id)       { file_set.noid }
        let(:body)     { { uri: 'https://iiif.example/iiif/3/abc.jp2' } }
        before do
          allow_any_instance_of(FileSetsController).to receive(:sleep)
          allow(DelegateUpdater).to receive(:call).and_raise(Valkyrie::Persistence::StaleObjectError)
        end
        run_test! do |response|
          expect(JSON.parse(response.body)['error']).to eq('stale_resource')
        end
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
