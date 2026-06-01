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
        Creates a Collection as a child of the given Community.

        Optional `depositor` is the NUID to stamp as the intellectual
        owner — the same anonymous-batch configuration shape that
        `WorksController#create` supports for inheriting Work-level
        depositors.
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          parent_id: { type: :string, description: 'NOID of the parent Community' },
          depositor: { type: :string, description: 'NUID to stamp as the Collection depositor (optional)' }
        },
        required:   %w[parent_id]
      }

      response '200', 'collection created' do
        let(:body) { { parent_id: community.noid } }
        schema '$ref' => '#/components/schemas/Collection'
        run_test!
      end

      response '200', 'create with explicit depositor stamps the resource' do
        let(:body) { { parent_id: community.noid, depositor: '900000001' } }
        schema '$ref' => '#/components/schemas/Collection'
        run_test! do |response|
          json = JSON.parse(response.body).fetch('collection')
          expect(json['depositor']).to eq('900000001')
        end
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

    patch 'Update a collection' do
      tags 'Collections'
      consumes 'multipart/form-data'
      produces 'application/json'
      description <<~DESC
        Update descriptive metadata on a Collection. Either supply a
        `binary` MODS XML upload or `metadata[*]` form fields.

        Thumbnail-family URI writes have their own purpose-specific
        endpoint — see `PATCH /collections/{id}/thumbnails`.
      DESC
      parameter name: 'metadata[title]',         in: :formData, required: false
      parameter name: 'metadata[description]',   in: :formData, required: false
      parameter name: :binary,                   in: :formData, required: false
      multipart_request_body(
        {
          'metadata[title]':       { type: :string },
          'metadata[description]': { type: :string },
          binary:                  { type: :string, format: :binary, description: 'MODS XML to apply to the Collection' }
        }
      )

      response '200', 'collection updated' do
        let(:collection)         { CollectionCreator.call(parent_id: community.noid) }
        let(:id)                 { collection.noid }
        let(:'metadata[title]')  { 'Updated' }
        schema '$ref' => '#/components/schemas/Collection'
        run_test!
      end
    end

    delete 'Destroy a collection' do
      tags 'Collections'

      response '204', 'collection destroyed' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)         { collection.noid }
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

  path '/collections/{id}/ancestors' do
    parameter name: :id, in: :path, type: :string

    get 'List ancestors of a collection' do
      tags 'Collections'
      produces 'application/json'
      description 'Returns the ancestor chain as an array of [noid, type-name] pairs.'

      response '200', 'ancestors listed' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)         { collection.noid }
        schema '$ref' => '#/components/schemas/Lineage'
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

  path '/collections/{id}/thumbnails' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Collection'

    patch 'Attach thumbnail-family IIIF Delegate URIs to a collection' do
      tags 'Collections'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Upserts one or more thumbnail-tier Delegates on the Collection
        (85px `thumbnail`, 170px `thumbnail_2x`, 500px `preview`). Missing
        keys are left untouched. Mirrors the Works endpoint of the same
        shape; collection-level thumbnails surface in the Cerberus
        browse UI.
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          thumbnail:    { type: :string, description: 'IIIF URL for the 85px thumbnail tier' },
          thumbnail_2x: { type: :string, description: 'IIIF URL for the 170px retina thumbnail tier' },
          preview:      { type: :string, description: 'IIIF URL for the 500px hero preview tier' }
        }
      }

      response '200', 'all three thumbnail-family keys land in one PATCH' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id) { collection.noid }
        let(:body) do
          {
            thumbnail:    'https://iiif.example/iiif/3/c.jp2/full/!85,85/0/default.jpg',
            thumbnail_2x: 'https://iiif.example/iiif/3/c.jp2/full/!170,170/0/default.jpg',
            preview:      'https://iiif.example/iiif/3/c.jp2/full/500,/0/default.jpg'
          }
        end
        schema '$ref' => '#/components/schemas/Collection'
        run_test! do |response|
          json = JSON.parse(response.body).fetch('collection')
          expect(json['thumbnail']).to eq('https://iiif.example/iiif/3/c.jp2/full/!85,85/0/default.jpg')
          expect(json['thumbnail_2x']).to eq('https://iiif.example/iiif/3/c.jp2/full/!170,170/0/default.jpg')
          expect(json['preview']).to eq('https://iiif.example/iiif/3/c.jp2/full/500,/0/default.jpg')
        end
      end
    end
  end

  path '/collections/{id}/parent' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Collection to move'

    patch 'Re-parent a collection' do
      tags 'Collections'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Moves a Collection under a different parent Community or Collection.
        Re-projects the moved subtree's descendant collections so their cached
        ancestry stays correct; Works are never touched. Rejects cycles (the
        new parent being the collection itself or one of its descendants), bad
        parent types, and tombstoned node/parent with a 422.
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        required:   %w[parent_id],
        properties: { parent_id: { type: :string, description: 'NOID of the new parent Community or Collection' } }
      }

      response '200', 'collection moved under another collection' do
        let(:community)    { CommunityCreator.call }
        let(:destination)  { CollectionCreator.call(parent_id: community.noid) }
        let(:collection)   { CollectionCreator.call(parent_id: community.noid) }
        let(:id)           { collection.noid }
        let(:body)         { { parent_id: destination.noid } }
        schema '$ref' => '#/components/schemas/Collection'
        run_test! do |response|
          ancestors = JSON.parse(response.body).dig('collection', 'ancestors')
          expect(ancestors.map(&:first)).to include(destination.noid)
        end
      end

      response '422', 'rejects a move into the collection\'s own descendant (cycle)' do
        let(:community)  { CommunityCreator.call }
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:child)      { CollectionCreator.call(parent_id: collection.noid) }
        let(:id)         { collection.noid }
        let(:body)       { { parent_id: child.noid } }
        run_test! do |response|
          expect(JSON.parse(response.body)['error']).to eq('cycle')
        end
      end
    end
  end

  path '/collections/{id}/tombstone' do
    parameter name: :id, in: :path, type: :string

    post 'Tombstone a collection' do
      tags 'Collections'
      produces 'application/json'
      description 'Marks a Collection as tombstoned. Refuses with 422 if the collection has live (non-tombstoned) members.'

      response '200', 'collection tombstoned' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)         { collection.noid }
        schema '$ref' => '#/components/schemas/Collection'
        run_test!
      end

      response '422', 'collection has live members' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)         { collection.noid }
        before { WorkCreator.call(parent_id: collection.noid) }
        run_test!
      end
    end
  end

  path '/collections/{id}/restore' do
    parameter name: :id, in: :path, type: :string

    post 'Restore a tombstoned collection' do
      tags 'Collections'
      produces 'application/json'
      description 'Clears the tombstone flag on a Collection. Cerberus does not expose this — call from operator console.'

      response '200', 'collection restored' do
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

  # Gap C regression — an ACL-only metadata PATCH used to wipe
  # depositor / proxy_uploader because Permissions#permissions= unconditionally
  # wrote those slots. Plain RSpec example (not rswag) since the multipart
  # nested-params shape is awkward to document via parameter declarations.
  describe 'PATCH /collections/:id with ACL-only metadata preserves provenance' do
    it 'leaves depositor/proxy_uploader intact when metadata[permissions] omits them' do
      collection = CollectionCreator.call(
        parent_id:      community.noid,
        proxy_uploader: '000000002',
        depositor:      '900000001',
        actor_nuid:     '000000002'
      )
      expect(collection.depositor).to      eq('900000001')
      expect(collection.proxy_uploader).to eq('000000002')

      patch "/collections/#{collection.noid}",
            params: { metadata: { permissions: { read: ['public'], edit: [], edit_users: [] } } }

      expect(response).to have_http_status(:ok)
      reloaded = Collection.find(collection.noid)
      expect(reloaded.depositor).to      eq('900000001')
      expect(reloaded.proxy_uploader).to eq('000000002')
      expect(reloaded.read_groups.to_a).to eq(['public'])
    end
  end
end
