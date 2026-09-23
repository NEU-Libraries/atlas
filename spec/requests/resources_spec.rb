# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Resources', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  after { Atlas.persister.wipe! }

  # Read the projected catalog facet straight off a resource's Solr doc — the
  # reindex endpoints' observable effect (mirrors classification_indexer_spec).
  def classification_in_solr(resource)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: 'classification_ssim' }
    ).dig('response', 'docs').first&.fetch('classification_ssim', nil)
  end

  path '/resources/{id}' do
    parameter name: :id, in: :path, type: :string,
              description: 'NOID of a Work, Collection, Community, FileSet, Blob, Delegate or Person'

    get 'Resolve a resource by NOID' do
      tags 'Resources'
      produces 'application/json'
      description <<~DESC
        Generic resolver. Issues a 302 redirect to the typed endpoint
        (e.g. /works/{id}). Resolves the Valkyrie-backed resource types only,
        so a Compilation NOID answers 404 here and is served by
        /compilations/{id} instead.
      DESC

      response '302', 'redirect to typed resource' do
        let(:id) { work.noid }
        run_test!
      end
    end

    delete 'Purge a resource' do
      tags 'Resources'
      produces 'application/json'
      description <<~DESC
        Permanently removes the resource. This is a purge, not a withdrawal: it
        deletes the metadata, cascades into members (a Work's FileSets and
        their Blobs), and removes the OCFL objects that hold the preserved
        bytes — every retained revision, not only the current one. Nothing
        survives but the audit row, which records the NOIDs it removed.

        Use `POST /resources/{id}/tombstone` for the user-visible withdrawal
        path. That one keeps everything and can be reversed.

        Refused with `422 has_children` while any Community, Collection or Work
        is still a member — and unlike tombstone it refuses a member that is
        merely tombstoned, because a purge cannot be undone and a member left
        behind is orphaned for good.

        Admin only.
      DESC

      response '204', 'resource purged' do
        let(:id) { work.noid }
        run_test! do
          expect(Work.find(work.noid)).to be_nil
        end
      end

      response '422', 'container still has members' do
        let(:id) { collection.noid }
        before { work }
        run_test! do |response|
          expect(JSON.parse(response.body)['code']).to eq('has_children')
        end
      end

      response '404', 'unknown id' do
        let(:id) { 'does-not-exist' }
        run_test!
      end
    end
  end

  path '/resources/{id}/permissions' do
    parameter name: :id, in: :path, type: :string

    get 'Permission flags for a resource' do
      tags 'Resources'
      produces 'application/json'
      description <<~DESC
        The resource's own ACL envelope, gated on the caller's `:read` right
        over that resource rather than on the class — the envelope names the
        Grouper groups and the depositor's NUID, so handing it to a caller who
        may not read the resource would disclose the rights of something they
        cannot see.

        A caller refused the read gets **403** with the `{ error, action,
        subject }` ability envelope; an id that resolves to nothing gets
        **404**. The two are distinct at the wire, and a client is expected to
        keep them distinct: "may not see it" is a sign-in prompt, "is not
        there" is a dead link.
      DESC
      security [{ BearerAuth: [] }]
      parameter name: :Authorization, in: :header, type: :string, required: false
      # Declaring the header makes it a required `let` for every example here,
      # and an rswag-sent value wins over the suite default — so restate the
      # default admin assertion and let the 403 example override it.
      let(:Authorization) { "Bearer #{DefaultAuthHeaders.admin_assertion}" }

      # Wire contract: a resource with no embargo reports null, even though the
      # attribute itself may be holding the setter's '' — clients read one shape
      # for "no embargo", not two.
      response '200', 'permissions returned' do
        let(:id) { work.noid }
        schema '$ref' => '#/components/schemas/Permissions'
        run_test! do |response|
          expect(response.parsed_body.dig('resource', 'embargo')).to be_nil
        end
      end

      response '403', 'caller may not read the resource' do
        let!(:outsider) do
          User.create!(email: 'outsider@example.edu', password: SecureRandom.hex(16),
                       nuid: '009999998', name: 'Student, Sam', role: :standard)
        end
        let(:id) { work.noid }
        # A real authenticated principal holding no grant on this tree: the
        # fixture Community is born private and WorkCreator copies that down.
        let(:Authorization) { "Bearer #{DefaultAuthHeaders.assertion_for('009999998')}" }
        run_test! do |response|
          expect(response.parsed_body['action']).to eq('read')
        end
      end

      response '404', 'unknown id' do
        let(:id) { 'does-not-exist' }
        run_test!
      end
    end

    patch "Adjust a resource's ACL" do
      tags 'Resources'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Adjusts the resource's ACL. PATCH, and the verb is honoured per key: a
        key the payload omits keeps its stored value, and a key sent explicitly
        empty is cleared. So changing one slot needs no read-the-whole-envelope
        round trip. Accepts `embargo`, `depositor`, `proxy_uploader`,
        `edit_users`, `read` and `edit`; anything else is ignored.

        Two rules bound the write. A resource may be no more visible than its
        container, so a read audience wider than the parent's is refused with
        `422 visibility_exceeds_parent` (widen the parent instead). And a group
        grant may only be removed by a member of that group — admin and the
        devolved-admin tier excepted; a grant the caller cannot remove is
        preserved rather than rejected, so the stored ACL may retain groups the
        request omitted. Read it back with `GET /resources/{id}/permissions`.

        Type-agnostic, and the response is the resource in its own typed shape.
        Descriptive fields are not writable here — MODS has its own path.
      DESC
      parameter name: :payload, in: :body, required: true, schema: {
        type:       :object,
        properties: {
          permissions: {
            type:       :object,
            properties: {
              embargo:        { type: :string, description: 'Release date, or empty to clear' },
              depositor:      { type: :string },
              proxy_uploader: { type: :string },
              edit_users:     { type: :array, items: { type: :string } },
              read:           { type: :array, items: { type: :string } },
              edit:           { type: :array, items: { type: :string } }
            }
          }
        },
        required:   ['permissions']
      }

      response '200', 'acl adjusted' do
        let(:id)      { work.noid }
        let(:payload) { { permissions: { read: [] } } }
        schema '$ref' => '#/components/schemas/Work'
        run_test!
      end

      response '404', 'unknown id' do
        let(:id)      { 'does-not-exist' }
        let(:payload) { { permissions: { read: [] } } }
        run_test!
      end
    end
  end

  path '/resources/{id}/mods' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of any Modsable resource (Work, Collection, Community)'

    get 'Retrieve current MODS metadata for any resource' do
      tags 'Resources'
      produces 'application/xml', 'application/json'
      description <<~DESC
        Type-agnostic current MODS: resolves the NOID and returns the resource's
        descriptive MODS without the caller knowing whether it is a Work,
        Collection, or Community. Output is byte-identical to the typed
        /works|collections|communities/{id}/mods routes (same views). Returns
        the JSON projection by default; append the .xml format suffix
        (/resources/{id}/mods.xml) for MODS XML. 404 for an unknown id, a
        non-Modsable resource, or one with no MODS.
      DESC

      response '200', 'current mods returned' do
        let(:id)     { work.noid }
        let(:Accept) { 'application/xml' }
        run_test!
      end

      response '404', 'unknown id / non-Modsable / no MODS' do
        let(:id)     { 'neu:nonexistent' }
        let(:Accept) { 'application/xml' }
        run_test!
      end
    end

    put "Replace a resource's MODS document" do
      tags 'Resources'
      consumes 'multipart/form-data'
      produces 'application/json'
      description <<~DESC
        Replaces the resource's descriptive metadata with the supplied `binary`
        MODS XML upload. PUT and not PATCH because the caller assembles the
        full document: descriptive merge logic lives in the client, e.g.
        Cerberus, not Atlas.

        Type-agnostic — the NOID is resolved and the write applies to a Work,
        Collection or Community alike. A type that holds no MODS answers 404,
        exactly as the GET on this path does. A request with no `binary`
        attached is a 422.

        Responds with the resource in its own typed shape, so the body matches
        what `GET /{type}/{id}` returns.
      DESC
      parameter name: :binary, in: :formData, required: false
      parameter name: :origin, in: :formData, required: false
      multipart_request_body(
        {
          binary: { type: :string, format: :binary, description: 'MODS XML to apply to the resource' },
          origin: { type: :string, description: ORIGIN_PARAM_DESCRIPTION }
        }
      )

      response '200', 'mods replaced' do
        let(:id)     { work.noid }
        let(:binary) { Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) }
        schema '$ref' => '#/components/schemas/Work'
        run_test!
      end

      response '404', 'unknown id, or a type that holds no MODS' do
        let(:id)     { 'does-not-exist' }
        let(:binary) { Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) }
        run_test!
      end

      response '422', 'no document attached' do
        let(:id)     { work.noid }
        let(:binary) { nil }
        run_test!
      end

      response '409', 'optimistic-lock conflict (surfaced immediately, not retried)' do
        let(:id)     { work.noid }
        let(:binary) { Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) }
        before do
          work # persist before stubbing so the creator's saves don't hit the stub
          allow(Atlas.persister).to receive(:save).and_raise(Valkyrie::Persistence::StaleObjectError)
        end
        run_test! do |response|
          expect(JSON.parse(response.body)['error']).to eq('stale_resource')
        end
      end
    end
  end

  # Polymorphic dispatch + per-format output across the three Modsable types.
  # Not rswag (one 200 example already documents the operation); these prove the
  # resolved klass drives the SAME typed view, so output stays byte-identical.
  describe 'GET /resources/:id/mods (polymorphic dispatch)' do
    it 'returns a Collection\'s current MODS XML via the .xml suffix' do
      get "/resources/#{collection.noid}/mods.xml"
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include('xml')
      expect(response.body).to start_with('<?xml')
    end

    it 'returns a Community\'s current MODS XML via the .xml suffix' do
      get "/resources/#{community.noid}/mods.xml"
      expect(response).to have_http_status(:ok)
      expect(response.body).to start_with('<?xml')
    end

    it 'renders the type-keyed JSON projection by default (a Work under the "work" key)' do
      get "/resources/#{work.noid}/mods"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to have_key('work')
    end

    it 'XML output byte-matches the typed collection route (no drift)' do
      get "/resources/#{collection.noid}/mods.xml"
      polymorphic = response.body
      get "/collections/#{collection.noid}/mods.xml"

      expect(polymorphic).to eq(response.body)
    end

    it 'JSON output byte-matches the typed collection route (no drift)' do
      get "/resources/#{collection.noid}/mods.json"
      polymorphic = response.body
      get "/collections/#{collection.noid}/mods.json"

      expect(polymorphic).to eq(response.body)
    end

    it '404s for a non-Modsable resource (FileSet)' do
      file_set = FileSetCreator.call(work_id: work.noid, classification: Classification.image)
      get "/resources/#{file_set.noid}/mods.xml"
      expect(response).to have_http_status(:not_found)
    end

    it '404s for an unknown id' do
      get '/resources/neu:missing/mods'
      expect(response).to have_http_status(:not_found)
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

        Admin-gated, like the File version list, because the descriptors expose
        edit attribution (the devolved-admin tier — :privileged role + the
        repository:admin group — can also reach this; `/history` stays
        admin-only). A resource with no MODS yields `{ "versions": [] }`.
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

  path '/resources/{id}/thumbnails' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the resource'

    patch 'Attach thumbnail-family IIIF Delegate URIs to a resource' do
      tags 'Resources'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Upserts one or more thumbnail-tier Delegates — the 85px `thumbnail`,
        the 170px `thumbnail_2x`, and the 500px hero `preview`. Each non-blank
        URI is dispatched to its matching Role; a key you omit is left
        untouched.

        Purpose-specific: machine-set IIIF URLs, a fixed three-key shape, no
        user content. Type-agnostic, and the response is the resource in its
        own typed shape.

        Retry-safe: an optimistic-lock conflict is retried internally, and only
        an exhausted budget surfaces as `409 stale_resource`.
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          thumbnail:    { type: :string, description: 'IIIF URI for the ~85px square thumbnail' },
          thumbnail_2x: { type: :string, description: 'IIIF URI for the ~170px square 2x thumbnail' },
          preview:      { type: :string, description: 'IIIF URI for the ~500px-wide preview' }
        }
      }

      response '200', 'delegate uris attached' do
        let(:id)   { work.noid }
        let(:body) { { thumbnail: 'https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg' } }
        schema '$ref' => '#/components/schemas/Work'
        run_test!
      end

      response '404', 'unknown id' do
        let(:id)   { 'does-not-exist' }
        let(:body) { { thumbnail: 'https://iiif.example/85.jpg' } }
        run_test!
      end
    end
  end

  path '/resources/{id}/parent' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the resource to move'

    patch 'Re-parent a resource' do
      tags 'Resources'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Moves a resource under a different parent. A Work carries no ancestry
        field and has no descendants, so only its own membership changes; a
        container's moved subtree is re-projected synchronously. Permissions
        are untouched. Omit `parent_id` to move a Community to the top of the
        tree.

        Authorization is TWO-SIDED — the caller needs `:reparent` on the moved
        node AND on the destination. Edit rights do not imply it for anyone but
        admin and the devolved-admin tier.

        A given-but-unresolvable `parent_id` is a `422 parent_not_found`, not a
        404: the parent is request input, not the addressed resource. A
        structurally invalid move (wrong parent type, a cycle, a tombstoned
        node or parent) is also a 422.
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: { parent_id: { type: :string, description: 'NOID of the destination' } }
      }

      response '200', 'resource moved' do
        let(:destination) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)          { work.noid }
        let(:body)        { { parent_id: destination.noid } }
        schema '$ref' => '#/components/schemas/Work'
        run_test! do |response|
          ancestors = JSON.parse(response.body).dig('work', 'ancestors')
          expect(ancestors.pluck('noid')).to include(destination.noid)
        end
      end

      response '404', 'unknown id' do
        let(:id)   { 'does-not-exist' }
        let(:body) { { parent_id: collection.noid } }
        run_test!
      end

      response '422', 'destination does not resolve' do
        let(:id)   { work.noid }
        let(:body) { { parent_id: 'does-not-exist' } }
        run_test! do |response|
          expect(JSON.parse(response.body)['error']).to eq('parent_not_found')
        end
      end
    end
  end

  path '/resources/{id}/tombstone' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the resource'

    post 'Tombstone a resource' do
      tags 'Resources'
      produces 'application/json'
      description <<~DESC
        Withdraws the resource. Everything stays in storage and the withdrawal
        is reversible via `POST /resources/{id}/restore`; reads answer `410`
        with a withdrawn stub. Use `DELETE /resources/{id}` for the
        irreversible purge.

        Refused with `422 has_live_children` while the resource still holds a
        live Community, Collection or Work, so a withdrawal can never orphan a
        readable descendant — empty the tree leaf-first. A Work's FileSets and
        Blobs are not counted and ride along.

        Conflicts surface immediately as `409 stale_resource` rather than being
        retried: the caller decides whether a withdrawal still applies.
      DESC

      response '200', 'resource tombstoned' do
        let(:id) { work.noid }
        schema '$ref' => '#/components/schemas/Work'
        run_test! do |response|
          expect(JSON.parse(response.body).dig('work', 'tombstoned')).to be(true)
        end
      end

      response '422', 'container still holds live children' do
        let(:id) { collection.noid }
        before { work }
        run_test! do |response|
          expect(JSON.parse(response.body)['code']).to eq('has_live_children')
        end
      end

      response '404', 'unknown id' do
        let(:id) { 'does-not-exist' }
        run_test!
      end
    end
  end

  path '/resources/{id}/restore' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the resource'

    post 'Restore a tombstoned resource' do
      tags 'Resources'
      produces 'application/json'
      description <<~DESC
        Reverses a withdrawal: reads stop answering `410`. Admin only. No
        confirmation marker — restoring is itself reversible, by tombstoning
        again.
      DESC

      response '200', 'resource restored' do
        let(:tombstoned) do
          w = WorkCreator.call(parent_id: collection.noid)
          w.tombstone(by: '000000004')
          Atlas.persister.save(resource: w)
        end
        let(:id) { tombstoned.noid }
        schema '$ref' => '#/components/schemas/Work'
        run_test! do |response|
          expect(JSON.parse(response.body).dig('work', 'tombstoned')).to be(false)
        end
      end

      response '404', 'unknown id' do
        let(:id) { 'does-not-exist' }
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

  path '/resources/{id}/reindex' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of any resource'

    post 'Re-project a resource\'s Solr doc (system-only)' do
      tags 'Resources'
      produces 'application/json'
      description <<~DESC
        Operational, **system-gated** Solr re-projection. Re-derives the
        resource's Solr doc from the current Postgres/OCFL source of truth — no
        lifecycle transition, no audit event, no optimistic-lock bump. This is
        the supported lever after an indexer ships or changes (e.g.
        `classification_ssim`) and an already-finalized resource carries a
        stale/empty projection; previously the only option was to abuse a
        lifecycle transition (`POST /works/{id}/complete`). Idempotent.

        Requires the system bearer token paired with the system `User:` NUID
        header; any non-system caller is rejected (401/403). Unknown id → 404.
      DESC
      security [{ BearerAuth: [] }]
      parameter name: :Authorization, in: :header, type: :string, required: false
      parameter name: :User, in: :header, type: :string, required: false,
                description: 'System principal, e.g. "NUID 000000000"'

      let!(:system_user) do
        User.create!(email: 'system@example.com', password: SecureRandom.hex(16),
                     nuid: '000000000', role: :system)
      end
      let(:system_token) { 'test-system-token' }
      before do
        allow(Rails.application.credentials).to receive(:system_token).and_return(system_token)
      end
      let(:Authorization) { "Bearer #{system_token}" }
      let(:User) { "NUID #{system_user.nuid}" }

      response '204', 'resource re-projected from current state' do
        let(:id) { work.noid }
        before do
          # Manufacture drift: add a page FileSet to the still-in-progress Work.
          # FileSetCreator only re-projects a *completed* Work, so the Work's
          # own Solr doc keeps an empty classification_ssim — exactly the
          # stale-projection case this endpoint repairs.
          FileSetCreator.call(work_id: work.noid, classification: Classification.image)
          expect(classification_in_solr(work)).to be_nil
        end
        run_test! do |response|
          expect(response.body).to be_blank
          expect(classification_in_solr(work)).to contain_exactly('Image')
        end
      end

      response '404', 'unknown id' do
        let(:id) { 'does-not-exist' }
        run_test!
      end

      response '403', 'non-system caller is rejected' do
        let!(:standard) do
          User.create!(email: 'sue@example.edu', password: SecureRandom.hex(16),
                       nuid: '009999999', role: :standard)
        end
        let(:id) { work.noid }
        # A real, authenticated non-system principal (signed Cerberus assertion,
        # verified against the suite's default keyset stub). Authorized for
        # reads/writes but not the :system-only :reindex action.
        let(:Authorization) { "Bearer #{DefaultAuthHeaders.assertion_for('009999999')}" }
        let(:User) { nil }
        run_test!
      end
    end
  end

  path '/resources/{id}/reindex_subtree' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of any resource (subtree root)'

    post 'Re-project a resource and its full descendant subtree (system-only)' do
      tags 'Resources'
      produces 'application/json'
      description <<~DESC
        Operational, **system-gated** subtree Solr re-projection. Gathers the
        resource plus its full descendant subtree — descendant containers
        (Collection/Community) **and the Works beneath them**, a deliberate
        superset of the re-parent cascade so Work-level projections like
        `classification_ssim` refresh too — and re-derives each doc from the
        current Postgres/OCFL source of truth (no lifecycle/audit/lock bump).

        Rooted at a Collection it refreshes that Collection's contents; rooted
        at the top Community it backfills the whole repository. **Synchronous**
        by design — for a pathologically large subtree the caller roots lower or
        drives the cascade in chunks. Idempotent. Returns the count re-projected.
        Non-system callers are rejected (401/403); unknown id → 404.
      DESC
      security [{ BearerAuth: [] }]
      parameter name: :Authorization, in: :header, type: :string, required: false
      parameter name: :User, in: :header, type: :string, required: false,
                description: 'System principal, e.g. "NUID 000000000"'

      let!(:system_user) do
        User.create!(email: 'system@example.com', password: SecureRandom.hex(16),
                     nuid: '000000000', role: :system)
      end
      let(:system_token) { 'test-system-token' }
      before do
        allow(Rails.application.credentials).to receive(:system_token).and_return(system_token)
      end
      let(:Authorization) { "Bearer #{system_token}" }
      let(:User) { "NUID #{system_user.nuid}" }

      response '200', 'subtree re-projected; descendant Works refreshed' do
        let(:id) { collection.noid }
        before do
          # Drift the descendant Work (see single-reindex note). The subtree
          # gather must reach this Work, not just the Collection container.
          FileSetCreator.call(work_id: work.noid, classification: Classification.image)
          expect(classification_in_solr(work)).to be_nil
        end
        schema type: :object, properties: { reindexed: { type: :integer } }, required: %w[reindexed]
        run_test! do |response|
          # Collection (root container) + its member Work.
          expect(JSON.parse(response.body)['reindexed']).to eq(2)
          expect(classification_in_solr(work)).to contain_exactly('Image')

          # Idempotent: a re-run converges to the same set and same projection.
          post "/resources/#{collection.noid}/reindex_subtree",
               headers: { 'Authorization' => "Bearer #{system_token}", 'User' => "NUID #{system_user.nuid}" }
          expect(JSON.parse(response.body)['reindexed']).to eq(2)
          expect(classification_in_solr(work)).to contain_exactly('Image')
        end
      end

      response '404', 'unknown id' do
        let(:id) { 'does-not-exist' }
        run_test!
      end
    end
  end

  path '/resources/{id}/descendant_works' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of any resource (subtree root)'

    get 'Every Work beneath a resource, flattened (gated, paginated)' do
      tags 'Resources'
      produces 'application/json'
      description <<~DESC
        Resolves a resource's full descendant subtree to the Works it contains,
        at any depth — the structural counterpart to
        `GET /compilations/{id}/contents`. Same digest shape and query engine,
        but the container set is the resource's own subtree (self +
        `ancestor_ids_ssim` descendants) instead of a Set recipe.

        Gated per-Work to what the caller may read: public, one of the caller's
        read or edit groups, the caller as an edit user, or the caller as the
        depositor. Admins see everything. So a restricted Work never leaks via
        the subtree, and one the caller can edit is never hidden. Tombstoned
        works are dropped. Membership is **structural** (`a_member_of`) only;
        pass `include_linked=true` to also surface linked members
        (`a_linked_member_of`). Solr-side pagination via `page` / `per_page`
        (default 25, capped at 100). Unknown id → 404.
      DESC
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :per_page, in: :query, type: :integer, required: false
      parameter name: :include_linked, in: :query, type: :boolean, required: false,
                description: 'Include linked members (a_linked_member_of); structural-only by default'

      response '200', 'descendant works (transitively flattened, gated, paginated)' do
        schema '$ref' => '#/components/schemas/DescendantWorks'
        let(:id) { community.noid }
        let(:page) { nil }
        let(:per_page) { nil }
        let(:include_linked) { nil }
        before { work } # materialize community → collection → work
        run_test! do |response|
          payload = JSON.parse(response.body)
          expect(payload['works'].pluck('noid')).to include(work.noid)
          expect(payload['works'].first).to include('klass' => 'Work')
          expect(payload['pagination']).to include('page' => 1)
        end
      end

      response '404', 'unknown id' do
        let(:id) { 'does-not-exist' }
        let(:page) { nil }
        let(:per_page) { nil }
        let(:include_linked) { nil }
        run_test!
      end
    end
  end

  # Gating + structure — driven with an explicit principal matrix (guest /
  # read-group member), so the per-Work ACL and the structural-vs-linked
  # distinction are proven directly rather than through the admin-bypass
  # default. Fixtures mirror the /compilations/{id}/contents contents spec.
  describe 'GET /resources/:id/descendant_works (gating + structure)', default_auth: false do
    let(:reader_group) { 'northeastern:drs:test-readers' }

    let!(:guest_user) do
      User.create!(email: 'guest@example.com', password: SecureRandom.hex(16), role: :guest)
    end
    let!(:reader) do
      User.create!(email: 'reader@example.com', password: SecureRandom.hex(16),
                   nuid: '000000002', role: :standard, groups: [reader_group])
    end

    # The containers are public: the endpoint gates the ROOT on :read before it
    # flattens, so a caller who cannot see the container cannot enumerate what
    # is inside it. Per-Work gating below is what these examples exercise.
    let!(:community) { Atlas.persister.save(resource: Community.new(read_groups: ['public'])) }
    let!(:collection) do
      Atlas.persister.save(resource: Collection.new(a_member_of: community.id, read_groups: ['public']))
    end
    let!(:nested) do
      Atlas.persister.save(resource: Collection.new(a_member_of: collection.id, read_groups: ['public']))
    end
    let!(:other_collection) do
      Atlas.persister.save(resource: Collection.new(a_member_of: community.id, read_groups: ['public']))
    end

    let!(:work_in_collection) do
      Atlas.persister.save(resource: Work.new(a_member_of: collection.id, read_groups: ['public']))
    end
    let!(:nested_work) do
      Atlas.persister.save(resource: Work.new(a_member_of: nested.id, read_groups: ['public']))
    end
    let!(:private_work) do
      Atlas.persister.save(resource: Work.new(a_member_of: collection.id, read_groups: [reader_group]))
    end
    let!(:tombstoned_work) do
      Atlas.persister.save(resource: Work.new(a_member_of: collection.id, read_groups: ['public'],
                                              tombstoned: true))
    end
    let!(:stray_work) do
      Atlas.persister.save(resource: Work.new(a_member_of: other_collection.id, read_groups: ['public']))
    end
    let!(:linked_work) do
      Atlas.persister.save(resource: Work.new(a_member_of:        other_collection.id,
                                              a_linked_member_of: [collection.id],
                                              read_groups:        ['public']))
    end

    def descendant_noids(response)
      JSON.parse(response.body)['works'].pluck('noid')
    end

    it 'flattens the subtree transitively, gated to the caller, minus tombstones' do
      get "/resources/#{collection.noid}/descendant_works", headers: signed_auth_headers(reader.nuid)
      expect(response).to have_http_status(:ok)
      expect(descendant_noids(response)).to contain_exactly(
        work_in_collection.noid, # direct member of the root collection
        nested_work.noid,        # transitive: under a nested sub-collection
        private_work.noid        # visible via the reader's group
      )
      expect(descendant_noids(response))
        .not_to include(tombstoned_work.noid, stray_work.noid, linked_work.noid)
    end

    it 'hides works the caller may not read (guest sees public only)' do
      get "/resources/#{collection.noid}/descendant_works", headers: signed_auth_headers(nil)
      expect(response).to have_http_status(:ok)
      noids = descendant_noids(response)
      expect(noids).to contain_exactly(work_in_collection.noid, nested_work.noid)
      expect(noids).not_to include(private_work.noid)
    end

    describe 'edit rights imply read' do
      let(:staff) do
        User.create!(email: 'staff@example.com', password: SecureRandom.hex(16),
                     nuid: '000000003', role: :privileged, groups: [Permissions::STAFF_EDIT_GROUP])
      end
      let(:depositor) do
        User.create!(email: 'depositor@example.com', password: SecureRandom.hex(16),
                     nuid: '000000005', role: :standard, groups: [])
      end
      # Readable by nobody's read group: reachable only through an edit grant.
      let!(:staff_edited_work) do
        Atlas.persister.save(resource: Work.new(a_member_of: collection.id, read_groups: [],
                                                edit_groups: [Permissions::STAFF_EDIT_GROUP]))
      end
      let!(:deposited_work) do
        Atlas.persister.save(resource: Work.new(a_member_of: collection.id, read_groups: [],
                                                depositor: depositor.nuid))
      end

      it 'lists a Work to a caller whose group may only edit it' do
        get "/resources/#{collection.noid}/descendant_works", headers: signed_auth_headers(staff.nuid)
        expect(descendant_noids(response)).to include(staff_edited_work.noid)
        expect(descendant_noids(response)).not_to include(deposited_work.noid)
      end

      it "lists a depositor's own private Work to them" do
        get "/resources/#{collection.noid}/descendant_works", headers: signed_auth_headers(depositor.nuid)
        expect(descendant_noids(response)).to include(deposited_work.noid)
        expect(descendant_noids(response)).not_to include(staff_edited_work.noid)
      end

      it 'still hides both from a caller with neither' do
        get "/resources/#{collection.noid}/descendant_works", headers: signed_auth_headers(reader.nuid)
        expect(descendant_noids(response)).not_to include(staff_edited_work.noid, deposited_work.noid)
      end
    end

    it 'is structural by default; ?include_linked=true unions linked members' do
      get "/resources/#{collection.noid}/descendant_works", headers: signed_auth_headers(nil)
      expect(descendant_noids(response)).not_to include(linked_work.noid)

      get "/resources/#{collection.noid}/descendant_works?include_linked=true", headers: signed_auth_headers(nil)
      expect(descendant_noids(response)).to include(linked_work.noid)
    end

    it 'paginates Solr-side (page/per_page)' do
      get "/resources/#{collection.noid}/descendant_works?per_page=2&page=1",
          headers: signed_auth_headers(reader.nuid)
      payload = response.parsed_body
      expect(payload['works'].length).to eq(2)
      expect(payload['pagination']).to eq('total' => 3, 'page' => 1, 'per_page' => 2, 'pages' => 2)
    end
  end
end
