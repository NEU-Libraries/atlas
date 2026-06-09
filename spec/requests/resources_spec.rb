# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Resources', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  after { Atlas.persister.wipe! }

  path '/resources/{id}' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of any resource (Work, Collection, Community, FileSet)'

    get 'Resolve a resource by NOID' do
      tags 'Resources'
      produces 'application/json'
      description 'Generic resolver. Issues a 302 redirect to the typed endpoint (e.g. `/works/{id}`).'

      response '302', 'redirect to typed resource' do
        let(:id) { work.noid }
        run_test!
      end
    end
  end

  path '/resources/{id}/permissions' do
    parameter name: :id, in: :path, type: :string

    get 'Permission flags for a resource' do
      tags 'Resources'
      produces 'application/json'

      response '200', 'permissions returned' do
        let(:id) { work.noid }
        schema '$ref' => '#/components/schemas/Permissions'
        run_test!
      end
    end
  end

  path '/resources/{id}/mods/versions' do
    parameter name: :id, in: :path, type: :string

    get 'List MODS version history for a resource' do
      tags 'Resources'
      produces 'application/json'
      description <<~DESC
        Reverse-chronological list of retained MODS versions for any Modsable
        resource (Work / Collection / Community). Each descriptor carries the
        OCFL version label and creation time, plus actor attribution correlated
        from the audit log (`actor_nuid` etc. are null when no edit event
        matches — e.g. the seed version a resource is born with).

        Admin-gated, like `/history`, because the descriptors expose the same
        edit attribution. A resource with no MODS yields `{ "versions": [] }`.
      DESC

      response '200', 'versions listed (newest first)' do
        let(:id) { work.noid }
        schema '$ref' => '#/components/schemas/ModsVersions'
        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['resource_id']).to eq(work.noid)
          # A freshly created Work carries its seed MODS version. Labels are
          # opaque OCFL vN (the Blob's envelope occupies earlier versions),
          # so assert presence, not a literal label.
          expect(body['versions'].first['version_id']).to match(/\Av\d+\z/)
        end
      end
    end
  end

  path '/resources/{id}/mods/versions/{version_id}' do
    parameter name: :id, in: :path, type: :string
    parameter name: :version_id, in: :path, type: :string, description: 'OCFL version label, e.g. v1'

    get 'Fetch MODS XML as of a specific version' do
      tags 'Resources'
      produces 'application/xml'
      description <<~DESC
        Returns the raw historical descMetadata.xml as of the given OCFL
        version. XML only — the JSON access copy is overwritten in place and
        is not version-recoverable. Unknown version or absent MODS → 404.
      DESC

      response '200', 'historical MODS XML returned' do
        let(:id) { work.noid }
        # The Work's current (head) MODS version — opaque OCFL label.
        let(:version_id) { Work.find(work.noid).mods_blob.latest_revision.to_s.split('/')[-2] }
        run_test!
      end

      response '404', 'unknown version' do
        let(:id)         { work.noid }
        let(:version_id) { 'v9999' }
        run_test!
      end
    end
  end

  path '/resources/preview' do
    post 'Render a temporary resource preview' do
      tags 'Resources'
      consumes 'multipart/form-data'
      produces 'text/html'
      description 'Given raw MODS XML, renders an HTML preview without persisting. Used by the loader/editor surface.'
      parameter name: :binary, in: :formData, required: true
      multipart_request_body(
        { binary: { type: :string, format: :binary, description: 'MODS XML to preview' } },
        required: %i[binary]
      )

      response '200', 'preview rendered' do
        let(:binary) { Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) }
        run_test!
      end
    end
  end

  path '/resources/find_many' do
    post 'Resolve many resources by id in one round-trip' do
      tags 'Resources'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Batch resolver. Takes a list of NOIDs and returns a lightweight digest
        per resolvable resource in a single index-backed query, collapsing a
        per-id find fan-out into one request.

        The result is **unordered** and **may be shorter than the input**:
        unresolvable ids are dropped silently. Tombstoned resources are kept
        but flagged (`tombstoned: true`) so callers can render a placeholder.
        Callers should index the result by `noid`.
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          ids: { type: :array, items: { type: :string }, description: 'NOIDs to resolve' }
        },
        required:   %w[ids]
      }

      response '200', 'digests for the resolvable subset' do
        let(:body) { { ids: [community.noid, collection.noid, 'does-not-exist'] } }
        before do
          set_mods_primary_title!(community,  'Root Community')
          set_mods_primary_title!(collection, 'Child Collection')
        end
        schema '$ref' => '#/components/schemas/ResourceDigests'
        run_test! do |response|
          digests = JSON.parse(response.body)
          by_noid = digests.index_by { |d| d['noid'] }
          expect(by_noid.keys).to contain_exactly(community.noid, collection.noid)
          expect(by_noid[community.noid]).to include(
            'id' => community.noid, 'klass' => 'Community', 'title' => 'Root Community', 'tombstoned' => false
          )
          expect(by_noid[collection.noid]).to include('klass' => 'Collection', 'title' => 'Child Collection')
        end
      end

      response '200', 'tombstoned resources are kept but flagged' do
        let(:body) { { ids: [work.noid] } }
        before do
          work.tombstoned = true
          Atlas.persister.save(resource: work)
        end
        schema '$ref' => '#/components/schemas/ResourceDigests'
        run_test! do |response|
          digests = JSON.parse(response.body)
          expect(digests.size).to eq(1)
          expect(digests.first).to include('noid' => work.noid, 'tombstoned' => true)
        end
      end

      response '200', 'empty id list returns an empty array' do
        let(:body) { { ids: [] } }
        schema '$ref' => '#/components/schemas/ResourceDigests'
        run_test! do |response|
          expect(JSON.parse(response.body)).to eq([])
        end
      end
    end
  end
end
