# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Collections', type: :request do
  let(:community) { CommunityCreator.call }

  after { Atlas.persister.wipe! }

  path '/collections' do
    get 'List collections' do
      tags 'Collections'
      produces 'application/json'

      response '200', 'collections listed' do
        before { 2.times { CollectionCreator.call(parent_id: community.noid) } }
        schema '$ref' => '#/components/schemas/CollectionsIndex'
        run_test!
      end
    end

    post 'Create a collection' do
      tags 'Collections'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Creates a Collection as a child of the given Community or Collection.

        The caller must hold edit rights on that parent — a Grouper edit
        grant, or ownership of it (its `depositor`). Otherwise `403`.
        `parent_id` is required: a blank or unresolvable one is `404`.

        Optional `depositor` is the NUID to stamp as the intellectual
        owner — the same anonymous-batch configuration shape that
        `WorksController#create` supports for inheriting Work-level
        depositors.
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          parent_id: { type: :string, description: 'NOID of the parent Community or Collection' },
          depositor: { type: :string, description: 'NUID to stamp as the Collection depositor (optional)' },
          featured:  { type: :boolean, description: 'Mark as a genre-showcase ("Featured") Collection (optional)' }
        },
        required:   %w[parent_id]
      }
      parameter name: :Authorization, in: :header, type: :string, required: false

      response '200', 'collection created' do
        let(:body) { { parent_id: community.noid } }
        schema '$ref' => '#/components/schemas/Collection'
        run_test! do |response|
          # Defaults to not-featured.
          expect(JSON.parse(response.body).dig('collection', 'featured')).to be(false)
        end
      end

      response '200', 'create a featured showcase collection' do
        let(:body) { { parent_id: community.noid, featured: true } }
        schema '$ref' => '#/components/schemas/Collection'
        run_test! do |response|
          expect(JSON.parse(response.body).dig('collection', 'featured')).to be(true)
        end
      end

      response '200', 'create with explicit depositor stamps the resource' do
        let(:body) { { parent_id: community.noid, depositor: '900000001' } }
        schema '$ref' => '#/components/schemas/Collection'
        run_test! do |response|
          json = JSON.parse(response.body).fetch('collection')
          expect(json['depositor']).to eq('900000001')
        end
      end

      response '403', 'caller holds no edit rights on the parent' do
        let!(:outsider) do
          User.create!(email: 'outsider@example.invalid', password: SecureRandom.hex(16),
                       nuid: '009999998', name: 'Outsider, Ola', role: :standard,
                       groups: ['northeastern:drs:library:dsg_students'])
        end
        let(:body)          { { parent_id: community.noid } }
        let(:Authorization) { "Bearer #{DefaultAuthHeaders.assertion_for('009999998')}" }
        run_test!
      end

      response '404', 'parent_id missing or unresolvable' do
        let(:body) { { parent_id: '' } }
        run_test!
      end
    end
  end

  path '/collections/{id}' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Collection'

    get 'Retrieve a collection' do
      tags 'Collections'
      produces 'application/json'

      response '200', 'collection found' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)         { collection.noid }
        schema '$ref' => '#/components/schemas/Collection'
        run_test!
      end

      response '410', 'collection tombstoned' do
        let(:collection) do
          c = CollectionCreator.call(parent_id: community.noid)
          c.tombstoned = true
          Atlas.persister.save(resource: c)
        end
        let(:id) { collection.noid }
        schema '$ref' => '#/components/schemas/Collection'
        run_test!
      end
    end
  end

  path '/collections/{id}/mods' do
    parameter name: :id, in: :path, type: :string

    get 'Retrieve MODS metadata for a collection' do
      tags 'Collections'
      produces 'application/xml', 'application/json'

      response '200', 'mods returned' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)         { collection.noid }
        let(:Accept)     { 'application/xml' }
        run_test!
      end
    end
  end

  path '/collections/{id}/featured' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Collection'

    let(:collection) { CollectionCreator.call(parent_id: community.noid) }

    patch 'Set a collection’s showcase Featured flag' do
      tags 'Collections'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Toggles the showcase `featured` flag. A resource-attribute write, not
        MODS and not the ACL, so it has its own path rather than a third
        payload shape on a shared one. Collection-only: no other type carries
        the flag, which is why this write stays typed while the rest moved to
        `/resources/{id}`.
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        required:   %w[featured],
        properties: { featured: { type: :boolean } }
      }

      response '200', 'flag set' do
        let(:id)   { collection.noid }
        let(:body) { { featured: true } }
        schema '$ref' => '#/components/schemas/Collection'
        run_test! do |response|
          expect(JSON.parse(response.body).dig('collection', 'featured')).to be(true)
        end
      end

      response '404', 'unknown id' do
        let(:id)   { 'does-not-exist' }
        let(:body) { { featured: true } }
        run_test!
      end
    end
  end

  path '/collections/{id}/children' do
    parameter name: :id, in: :path, type: :string

    get 'List child noids of a collection' do
      tags 'Collections'
      produces 'application/json'

      response '200', 'children listed' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)         { collection.noid }
        schema type: :array, items: { type: :string }
        run_test!
      end

      response '410', 'collection tombstoned' do
        let(:collection) do
          c = CollectionCreator.call(parent_id: community.noid)
          c.tombstoned = true
          Atlas.persister.save(resource: c)
        end
        let(:id) { collection.noid }
        schema '$ref' => '#/components/schemas/Collection'
        run_test!
      end
    end
  end

  # An ACL-only metadata PATCH must preserve depositor / proxy_uploader.
  # Permissions#permissions= writes the ACL slots; a naive version that also
  # wrote depositor/proxy_uploader would clear them whenever the caller omits
  # them. Plain RSpec example (not rswag) since the multipart nested-params
  # shape is awkward to document via parameter declarations.
  describe 'PATCH /collections/:id with ACL-only metadata preserves provenance' do
    # Public parent: the PATCH below grants a public read, which the containment
    # rule allows only under a public container.
    let(:community) { public_community! }

    it 'leaves depositor/proxy_uploader intact when the ACL payload omits them' do
      collection = CollectionCreator.call(
        parent_id:      community.noid,
        proxy_uploader: '000000002',
        depositor:      '900000001',
        actor_nuid:     '000000002'
      )
      expect(collection.depositor).to      eq('900000001')
      expect(collection.proxy_uploader).to eq('000000002')

      patch "/resources/#{collection.noid}/permissions",
            params: { permissions: { read: ['public'], edit: [], edit_users: [] } }

      expect(response).to have_http_status(:ok)
      reloaded = Collection.find(collection.noid)
      expect(reloaded.depositor).to      eq('900000001')
      expect(reloaded.proxy_uploader).to eq('000000002')
      expect(reloaded.read_groups.to_a).to eq(['public'])
    end
  end
end
