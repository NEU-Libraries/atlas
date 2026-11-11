# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Collections', type: :request do
  let(:community) { CommunityCreator.call }

  after { Atlas.persister.wipe! }

  path '/collections' do
    get 'List collections' do
      tags 'Collections'
      response_texts(
        '200' => 'One page of Collections.'
      )
      produces 'application/json'
      description <<~DESC
        Lists every Collection, one page at a time.

        Only an admin may call this; anyone else gets `403`.
      DESC
      paginated

      response '200', 'collections listed' do
        before { 2.times { CollectionCreator.call(parent_id: community.noid) } }
        schema '$ref' => '#/components/schemas/CollectionsIndex'
        run_test!
      end
    end

    post 'Create a collection' do
      tags 'Collections'
      response_texts(
        '200' => 'The new Collection.',
        '403' => 'The caller holds no edit rights on the parent.',
        '404' => 'The `parent_id` is missing or names nothing.',
        '422' => 'The parent is tombstoned.'
      )
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Creates a Collection as a child of the given Community or Collection.

        The caller must hold edit rights on that parent — a Grouper edit
        grant, or ownership of it (its `depositor`). Otherwise `403`.
        `parent_id` is required: a blank or unresolvable one is `404`.
        A tombstoned parent refuses the create with `422 tombstoned_parent`,
        after the edit-rights check.

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

      response '422', 'the parent is tombstoned' do
        let(:body) { { parent_id: community.noid } }
        before do
          community.tombstone(by: '000000004')
          Atlas.persister.save(resource: community)
        end
        run_test! do |response|
          expect(response.parsed_body['code']).to eq('tombstoned_parent')
          expect(community.children.grep(Collection)).to be_empty
        end
      end
    end
  end

  path '/collections/{id}' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Collection'

    get 'Retrieve a collection' do
      tags 'Collections'
      response_texts(
        '200' => 'The Collection.',
        '410' => 'The Collection is tombstoned or purged. For a tombstoned Collection an admin or delegated admin gets ' \
                 'the full record and everyone else a stub; a purged one answers everyone with a stub that says so.'
      )
      produces 'application/json'
      description <<~DESC
        Returns a Collection's record: its title and description, its ancestors,
        its thumbnails and its state.

        A tombstoned Collection answers `410`: an admin or delegated admin gets the
        full record, and everyone else gets a stub. A purged NOID answers `410` with
        a stub that names the Collection as purged, to every caller.
      DESC

      response '200', 'collection found' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)         { collection.noid }
        schema '$ref' => '#/components/schemas/Collection'
        run_test!
      end

      tombstoned_record_responses(full: 'Collection', withheld: 'CollectionTombstone', purged: true) do
        let(:id) { tombstoned_public_container!(Collection).noid }
      end
    end
  end

  path '/collections/{id}/mods' do
    parameter name: :id, in: :path, type: :string

    get 'Retrieve MODS metadata for a collection' do
      tags 'Collections'
      response_texts(
        '410' => 'The Collection is tombstoned; its metadata is withheld from everyone but admins and delegated admins.',
        '200' => 'The Collection\'s descriptive metadata, in the format requested.'
      )
      produces 'application/xml', 'application/json'
      description <<~DESC
        Returns the Collection's descriptive metadata. By default the body is the
        JSON access copy. Append `.xml` (`/collections/{id}/mods.xml`) for the MODS
        XML, which is the preservation copy, or `.html` for the rendered
        display. The `Accept` header does not change the format.

        A tombstoned Collection's metadata answers `410` with the `Tombstoned` body
        to everyone but admins and delegated admins.
      DESC

      withheld_by_tombstone do
        let(:id) { tombstoned_public_container!(Collection).noid }
      end

      response '200', 'mods returned' do
        json_schema :CollectionMods
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
      response_texts(
        '200' => 'The Collection, with its new `featured` value.',
        '404' => 'No Collection has that NOID.'
      )
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
      response_texts(
        '200' => 'The NOIDs of the Collection\'s direct children.',
        '410' => 'The Collection is tombstoned. An admin or delegated admin gets the full Collection record; everyone else ' \
                 'gets a stub.'
      )
      produces 'application/json'
      description <<~DESC
        Returns the NOIDs of the Collection's direct children, Works and
        Collections, tombstoned ones included.
        `POST /resources/find_many` resolves them all in one call and flags the
        tombstoned ones.

        A tombstoned Collection answers `410`: an admin or delegated admin gets the
        full record, and everyone else gets a stub.
      DESC

      response '200', 'children listed' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)         { collection.noid }
        schema type: :array, items: { type: :string }
        run_test!
      end

      tombstoned_record_responses(full: 'Collection', withheld: 'CollectionTombstone') do
        let(:id) { tombstoned_public_container!(Collection).noid }
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

  # The refusal sits behind the edit-rights check, so the 422 cannot tell a
  # caller without rights that the parent is tombstoned.
  describe 'POST /collections under a tombstoned parent, without edit rights', type: :request do
    let!(:outsider) do
      User.create!(email: 'outsider-tomb@example.invalid', password: SecureRandom.hex(16),
                   nuid: '009999995', name: 'Outsider, Ola', role: :standard, groups: [])
    end

    it 'answers 403, not 422' do
      community.tombstone(by: '000000004')
      Atlas.persister.save(resource: community)

      post '/collections', params:  { parent_id: community.noid }.to_json,
                           headers: signed_auth_headers(outsider.nuid).merge('Content-Type' => 'application/json')

      expect(response).to have_http_status(:forbidden)
    end
  end
end
