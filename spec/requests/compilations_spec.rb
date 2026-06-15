# frozen_string_literal: true

require 'swagger_helper'

# Drives the auth matrix explicitly (owner / other-user / admin / guest), so
# the default admin headers are opted out and every example states its
# principal. `curator` owns the Sets under test; `rando` is a signed-in
# non-owner; guest = no Authorization header at all (require_auth fallback).
RSpec.describe 'Compilations', type: :request, default_auth: false do
  let!(:guest_user) do
    User.create!(email: 'guest@example.com', password: SecureRandom.hex(16), role: :guest)
  end
  let!(:curator) do
    User.create!(email: 'curator@example.com', password: SecureRandom.hex(16),
                 nuid: '000000002', role: :standard,
                 groups: ['northeastern:drs:test-readers'])
  end
  let!(:rando) do
    User.create!(email: 'rando@example.com', password: SecureRandom.hex(16),
                 nuid: '000000003', role: :standard)
  end
  let!(:admin) do
    User.create!(email: 'admin@example.com', password: SecureRandom.hex(16),
                 nuid: '000000004', role: :admin)
  end

  # Authenticate via a Cerberus-signed assertion whose `sub` is the block's
  # principal. The `User:` header still goes
  # out (it's a declared param) but the server ignores it now — auth_header reads
  # it (via send, to dodge the `User` model constant) only to choose the sub.
  before do
    allow(Rails.application.credentials)
      .to receive(:cerberus_signing_keys)
      .and_return({ DefaultAuthHeaders::KID => DefaultAuthHeaders::SIGNING_KEY.public_to_pem })
  end

  let(:auth_header) do
    nuid = send(:User).to_s[/\ANUID (\S+)/, 1]
    "Bearer #{DefaultAuthHeaders.assertion_for(nuid)}" if nuid
  end

  def create_compilation(owner_user, title: 'My Set', **attrs)
    Compilation.create!(title: title, depositor: owner_user.nuid, **attrs)
  end

  path '/compilations' do
    get 'List compilations (owner-scoped)' do
      tags 'Compilations'
      produces 'application/json'
      description <<~D
        Paginated, newest-first listing of the caller's own Compilations.
        Pass `?owner=<nuid>` to list another user's Sets — admin-only.
        Pass `?q=<term>` to narrow by case-insensitive title substring;
        the filter applies before pagination, so the pagination block
        describes the filtered result. There is no public browse endpoint.
      D
      security [{ BearerAuth: [], NuidHeader: [] }]
      parameter name: :Authorization, in: :header, type: :string, required: false
      parameter name: :User, in: :header, type: :string, required: false
      parameter name: :owner, in: :query, type: :string, required: false,
                description: 'NUID whose Sets to list (admin-only); defaults to the caller'
      parameter name: :q, in: :query, type: :string, required: false,
                description: 'case-insensitive title substring filter'

      response '200', 'own compilations listed' do
        schema '$ref' => '#/components/schemas/CompilationsIndex'
        let(:Authorization) { auth_header }
        let(:User)  { "NUID #{curator.nuid}" }
        let(:owner) { nil }
        let(:q)     { nil }
        before do
          create_compilation(curator)
          create_compilation(rando, title: 'Not mine')
        end
        run_test! do |response|
          payload = JSON.parse(response.body)
          titles = payload['compilations'].map { |c| c.dig('compilation', 'title') }
          expect(titles).to eq(['My Set'])
        end
      end

      response '200', 'title-filtered listing', document: false do
        schema '$ref' => '#/components/schemas/CompilationsIndex'
        let(:Authorization) { auth_header }
        let(:User)  { "NUID #{curator.nuid}" }
        let(:owner) { nil }
        let(:q)     { 'course' }
        before do
          create_compilation(curator, title: 'Course readings')
          create_compilation(curator, title: 'Discourse and power') # substring match
          create_compilation(curator, title: 'Field notes')
          create_compilation(rando, title: 'Course readings') # other owner, stays invisible
        end
        run_test! do |response|
          payload = JSON.parse(response.body)
          titles = payload['compilations'].map { |c| c.dig('compilation', 'title') }
          expect(titles).to contain_exactly('Course readings', 'Discourse and power')
          expect(payload.dig('pagination', 'count')).to eq(2)
        end
      end

      response '403', 'cross-owner listing as a non-admin' do
        let(:Authorization) { auth_header }
        let(:User)  { "NUID #{rando.nuid}" }
        let(:owner) { curator.nuid }
        let(:q)     { nil }
        run_test!
      end
    end

    post 'Create a compilation' do
      tags 'Compilations'
      consumes 'application/json'
      produces 'application/json'
      description 'Creates a personal Set owned by the acting user (depositor is stamped ' \
                  'from the authenticated NUID). Born private: empty ACLs, no staff default.'
      security [{ BearerAuth: [], NuidHeader: [] }]
      parameter name: :Authorization, in: :header, type: :string, required: false
      parameter name: :User, in: :header, type: :string, required: false
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          title:       { type: :string },
          description: { type: :string }
        },
        required:   %w[title]
      }

      response '201', 'compilation created' do
        schema '$ref' => '#/components/schemas/Compilation'
        let(:Authorization) { auth_header }
        let(:User) { "NUID #{curator.nuid}" }
        let(:body) { { title: 'Course readings', description: 'HIST 1101' } }
        run_test! do |response|
          payload = JSON.parse(response.body)['compilation']
          expect(payload['depositor']).to eq(curator.nuid)
          expect(payload['id']).to be_present
          expect(payload['read_groups']).to eq([])
        end
      end

      response '403', 'guest cannot create' do
        let(:Authorization) { nil }
        let(:User) { nil }
        let(:body) { { title: 'Nope' } }
        run_test!
      end

      response '422', 'missing title' do
        let(:Authorization) { auth_header }
        let(:User) { "NUID #{curator.nuid}" }
        let(:body) { { description: 'no title supplied' } }
        run_test!
      end
    end
  end

  path '/compilations/{id}' do
    parameter name: :id, in: :path, type: :string, description: 'Compilation NOID'

    get 'Fetch a compilation' do
      tags 'Compilations'
      produces 'application/json'
      description 'Per-row visibility: owner, explicit read/edit grants, or public. ' \
                  'Public Sets are readable by unauthenticated (guest) callers — the CERES case.'
      security [{ BearerAuth: [], NuidHeader: [] }]
      parameter name: :Authorization, in: :header, type: :string, required: false
      parameter name: :User, in: :header, type: :string, required: false

      response '200', 'owner reads their set' do
        schema '$ref' => '#/components/schemas/Compilation'
        let(:compilation) { create_compilation(curator) }
        let(:id) { compilation.noid }
        let(:Authorization) { auth_header }
        let(:User) { "NUID #{curator.nuid}" }
        run_test! do |response|
          expect(JSON.parse(response.body).dig('compilation', 'id')).to eq(compilation.noid)
        end
      end

      response '200', 'guest reads a public set' do
        schema '$ref' => '#/components/schemas/Compilation'
        let(:compilation) do
          create_compilation(curator).tap { |c| c.publicize && c.save! }
        end
        let(:id) { compilation.noid }
        let(:Authorization) { nil }
        let(:User) { nil }
        run_test!
      end

      response '403', 'guest cannot read a private set' do
        let(:id) { create_compilation(curator).noid }
        let(:Authorization) { nil }
        let(:User) { nil }
        run_test!
      end

      response '404', 'unknown noid' do
        let(:id) { 'nope404' }
        let(:Authorization) { auth_header }
        let(:User) { "NUID #{curator.nuid}" }
        run_test!
      end
    end

    patch 'Update a compilation' do
      tags 'Compilations'
      consumes 'application/json'
      produces 'application/json'
      description <<~D
        Title/description edits plus an optional `permissions` ACL hash
        (read/edit groups + edit_users — replaces all three lists; the
        depositor is never writable). ACL changes emit a `permissions`
        audit event with before/after; no-op ACL writes are suppressed.
      D
      security [{ BearerAuth: [], NuidHeader: [] }]
      parameter name: :Authorization, in: :header, type: :string, required: false
      parameter name: :User, in: :header, type: :string, required: false
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          title:       { type: :string },
          description: { type: :string },
          permissions: {
            type:       :object,
            properties: {
              read:       { type: :array, items: { type: :string } },
              edit:       { type: :array, items: { type: :string } },
              edit_users: { type: :array, items: { type: :string } }
            }
          }
        }
      }

      response '200', 'title and ACL updated (audit row emitted, no-ops suppressed)' do
        schema '$ref' => '#/components/schemas/Compilation'
        let(:compilation) { create_compilation(curator) }
        let(:id) { compilation.noid }
        let(:Authorization) { auth_header }
        let(:User) { "NUID #{curator.nuid}" }
        let(:body) do
          { title: 'Renamed', permissions: { read: ['public'], edit: [], edit_users: [] } }
        end
        run_test! do |response|
          payload = JSON.parse(response.body)['compilation']
          expect(payload['title']).to eq('Renamed')
          expect(payload['read_groups']).to eq(['public'])

          events = AuditEvent.where(resource_type: 'Compilation', change_type: 'permissions')
          expect(events.count).to eq(1)
          expect(events.first.payload.dig('after', 'read')).to eq(['public'])

          # Re-applying the identical ACL is a non-event — no second row.
          patch "/compilations/#{compilation.noid}",
                params:  { permissions: { read: ['public'], edit: [], edit_users: [] } }.to_json,
                headers: { 'Authorization' => auth_header, 'User' => "NUID #{curator.nuid}",
                           'Content-Type'  => 'application/json' }
          expect(response).to have_http_status(:ok)
          expect(AuditEvent.where(resource_type: 'Compilation', change_type: 'permissions').count).to eq(1)
        end
      end

      response '200', 'edit_users grant lets a non-owner update' do
        schema '$ref' => '#/components/schemas/Compilation'
        let(:compilation) do
          create_compilation(curator, edit_users: [rando.nuid])
        end
        let(:id) { compilation.noid }
        let(:Authorization) { auth_header }
        let(:User) { "NUID #{rando.nuid}" }
        let(:body) { { title: 'Edited by grantee' } }
        run_test! do |response|
          expect(JSON.parse(response.body).dig('compilation', 'title')).to eq('Edited by grantee')
        end
      end

      response '403', 'non-owner without a grant' do
        let(:id) { create_compilation(curator).noid }
        let(:Authorization) { auth_header }
        let(:User) { "NUID #{rando.nuid}" }
        let(:body) { { title: 'Hijack' } }
        run_test!
      end
    end

    delete 'Destroy a compilation' do
      tags 'Compilations'
      description 'Owner (or edit-grantee / admin) only. Join rows cascade.'
      security [{ BearerAuth: [], NuidHeader: [] }]
      parameter name: :Authorization, in: :header, type: :string, required: false
      parameter name: :User, in: :header, type: :string, required: false

      response '204', 'compilation destroyed' do
        let(:id) { create_compilation(curator).noid }
        let(:Authorization) { auth_header }
        let(:User) { "NUID #{curator.nuid}" }
        run_test! do
          expect(Compilation.find_by(noid: id)).to be_nil
        end
      end

      response '403', 'non-owner cannot destroy' do
        let(:id) { create_compilation(curator).noid }
        let(:Authorization) { auth_header }
        let(:User) { "NUID #{rando.nuid}" }
        run_test!
      end

      response '404', 'unknown noid' do
        let(:id) { 'nope404' }
        let(:Authorization) { auth_header }
        let(:User) { "NUID #{curator.nuid}" }
        run_test!
      end
    end
  end

  # ---- membership (recipe) mutations ----
  # Shared seed tree for the recipe lines. Adds resolve the noid against
  # Valkyrie on create (type check); the response is always the updated
  # compilation partial.

  describe 'membership mutations' do
    let!(:community)  { Atlas.persister.save(resource: Community.new) }
    let!(:collection) { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
    let!(:work)       { Atlas.persister.save(resource: Work.new(a_member_of: collection.id)) }

    let(:compilation) { create_compilation(curator) }
    let(:id) { compilation.noid }

    path '/compilations/{id}/included_collections' do
      parameter name: :id, in: :path, type: :string, description: 'Compilation NOID'

      post 'Include a Collection (transitive)' do
        tags 'Compilations'
        consumes 'application/json'
        produces 'application/json'
        description 'Adds an include-collection recipe line. The noid must resolve to a ' \
                    'Collection (Communities and unknown noids are 422). Idempotent. ' \
                    'No audit row — recipe churn is personal curation.'
        security [{ BearerAuth: [], NuidHeader: [] }]
        parameter name: :Authorization, in: :header, type: :string, required: false
        parameter name: :User, in: :header, type: :string, required: false
        parameter name: :body, in: :body, schema: {
          type:       :object,
          properties: { collection_id: { type: :string, description: 'Collection NOID' } },
          required:   %w[collection_id]
        }

        response '200', 'collection included (idempotent)' do
          schema '$ref' => '#/components/schemas/Compilation'
          let(:Authorization) { auth_header }
          let(:User) { "NUID #{curator.nuid}" }
          let(:body) { { collection_id: collection.noid } }
          run_test! do |response|
            payload = JSON.parse(response.body)['compilation']
            expect(payload['included_collections']).to eq([collection.noid])

            # Re-adding the same collection is a no-op, not a 422/500.
            post "/compilations/#{compilation.noid}/included_collections",
                 params:  { collection_id: collection.noid }.to_json,
                 headers: { 'Authorization' => auth_header, 'User' => "NUID #{curator.nuid}",
                            'Content-Type'  => 'application/json' }
            expect(response).to have_http_status(:ok)
            expect(compilation.reload.included_collections).to eq([collection.noid])
          end
        end

        response '422', 'community noid rejected (no top-node includes)' do
          let(:Authorization) { auth_header }
          let(:User) { "NUID #{curator.nuid}" }
          let(:body) { { collection_id: community.noid } }
          run_test! do |response|
            expect(JSON.parse(response.body)['error']).to eq('invalid_record')
            expect(compilation.reload.included_collections).to be_empty
          end
        end

        response '403', 'non-owner cannot mutate the recipe' do
          let(:Authorization) { auth_header }
          let(:User) { "NUID #{rando.nuid}" }
          let(:body) { { collection_id: collection.noid } }
          run_test!
        end
      end
    end

    path '/compilations/{id}/included_collections/{collection_id}' do
      parameter name: :id, in: :path, type: :string, description: 'Compilation NOID'
      parameter name: :collection_id, in: :path, type: :string, description: 'Collection NOID'

      delete 'Remove an included Collection' do
        tags 'Compilations'
        produces 'application/json'
        description 'Idempotent: removing an absent inclusion is a 200 no-op.'
        security [{ BearerAuth: [], NuidHeader: [] }]
        parameter name: :Authorization, in: :header, type: :string, required: false
        parameter name: :User, in: :header, type: :string, required: false

        response '200', 'inclusion removed (or was already absent)' do
          schema '$ref' => '#/components/schemas/Compilation'
          let(:Authorization) { auth_header }
          let(:User) { "NUID #{curator.nuid}" }
          let(:collection_id) { collection.noid }
          before { compilation.collection_inclusions.create!(resource_noid: collection.noid) }
          run_test! do |response|
            expect(JSON.parse(response.body).dig('compilation', 'included_collections')).to eq([])

            # And again — absent row, still 200.
            delete "/compilations/#{compilation.noid}/included_collections/#{collection.noid}",
                   headers: { 'Authorization' => auth_header, 'User' => "NUID #{curator.nuid}" }
            expect(response).to have_http_status(:ok)
          end
        end
      end
    end

    path '/compilations/{id}/included_works' do
      parameter name: :id, in: :path, type: :string, description: 'Compilation NOID'

      post 'Include a Work individually' do
        tags 'Compilations'
        consumes 'application/json'
        produces 'application/json'
        description 'Adds an include-work recipe line. The noid must resolve to a Work. Idempotent.'
        security [{ BearerAuth: [], NuidHeader: [] }]
        parameter name: :Authorization, in: :header, type: :string, required: false
        parameter name: :User, in: :header, type: :string, required: false
        parameter name: :body, in: :body, schema: {
          type:       :object,
          properties: { work_id: { type: :string, description: 'Work NOID' } },
          required:   %w[work_id]
        }

        response '200', 'work included' do
          schema '$ref' => '#/components/schemas/Compilation'
          let(:Authorization) { auth_header }
          let(:User) { "NUID #{curator.nuid}" }
          let(:body) { { work_id: work.noid } }
          run_test! do |response|
            expect(JSON.parse(response.body).dig('compilation', 'included_works')).to eq([work.noid])
          end
        end

        response '422', 'collection noid rejected where a Work is expected' do
          let(:Authorization) { auth_header }
          let(:User) { "NUID #{curator.nuid}" }
          let(:body) { { work_id: collection.noid } }
          run_test!
        end

        response '403', 'guest cannot mutate the recipe' do
          let(:Authorization) { nil }
          let(:User) { nil }
          let(:body) { { work_id: work.noid } }
          before { compilation.tap { |c| c.publicize && c.save! } }
          run_test!
        end
      end
    end

    path '/compilations/{id}/included_works/{work_id}' do
      parameter name: :id, in: :path, type: :string, description: 'Compilation NOID'
      parameter name: :work_id, in: :path, type: :string, description: 'Work NOID'

      delete 'Remove an included Work' do
        tags 'Compilations'
        produces 'application/json'
        description 'Idempotent: removing an absent inclusion is a 200 no-op.'
        security [{ BearerAuth: [], NuidHeader: [] }]
        parameter name: :Authorization, in: :header, type: :string, required: false
        parameter name: :User, in: :header, type: :string, required: false

        response '200', 'inclusion removed' do
          schema '$ref' => '#/components/schemas/Compilation'
          let(:Authorization) { auth_header }
          let(:User) { "NUID #{curator.nuid}" }
          let(:work_id) { work.noid }
          before { compilation.work_inclusions.create!(resource_noid: work.noid) }
          run_test! do |response|
            expect(JSON.parse(response.body).dig('compilation', 'included_works')).to eq([])
          end
        end
      end
    end

    path '/compilations/{id}/exclusions' do
      parameter name: :id, in: :path, type: :string, description: 'Compilation NOID'

      post 'Set a Work aside' do
        tags 'Compilations'
        consumes 'application/json'
        produces 'application/json'
        description 'Adds a set-aside recipe line: the Work is subtracted from the resolved ' \
                    'union at read time. The noid must resolve to a Work. Idempotent.'
        security [{ BearerAuth: [], NuidHeader: [] }]
        parameter name: :Authorization, in: :header, type: :string, required: false
        parameter name: :User, in: :header, type: :string, required: false
        parameter name: :body, in: :body, schema: {
          type:       :object,
          properties: { work_id: { type: :string, description: 'Work NOID' } },
          required:   %w[work_id]
        }

        response '200', 'work set aside' do
          schema '$ref' => '#/components/schemas/Compilation'
          let(:Authorization) { auth_header }
          let(:User) { "NUID #{curator.nuid}" }
          let(:body) { { work_id: work.noid } }
          run_test! do |response|
            expect(JSON.parse(response.body).dig('compilation', 'excluded_works')).to eq([work.noid])
            expect(AuditEvent.where(resource_type: 'Compilation').count).to eq(0)
          end
        end
      end
    end

    path '/compilations/{id}/exclusions/{work_id}' do
      parameter name: :id, in: :path, type: :string, description: 'Compilation NOID'
      parameter name: :work_id, in: :path, type: :string, description: 'Work NOID'

      delete 'Clear a set-aside' do
        tags 'Compilations'
        produces 'application/json'
        description 'Idempotent: clearing an absent set-aside is a 200 no-op.'
        security [{ BearerAuth: [], NuidHeader: [] }]
        parameter name: :Authorization, in: :header, type: :string, required: false
        parameter name: :User, in: :header, type: :string, required: false

        response '200', 'set-aside cleared' do
          schema '$ref' => '#/components/schemas/Compilation'
          let(:Authorization) { auth_header }
          let(:User) { "NUID #{curator.nuid}" }
          let(:work_id) { work.noid }
          before { compilation.exclusions.create!(resource_noid: work.noid) }
          run_test! do |response|
            expect(JSON.parse(response.body).dig('compilation', 'excluded_works')).to eq([])
          end
        end
      end
    end
  end

  # ---- recipe resolution ----
  # Seed tree (all works public unless noted):
  #
  #   community
  #   ├─ collection (included in the recipe)
  #   │   ├─ nested ──── nested_work          (transitive descendant)
  #   │   ├─ work_in_collection
  #   │   ├─ private_work                     (read_groups: curator's group)
  #   │   ├─ tombstoned_work
  #   │   └─ excluded_work                    (set aside in the recipe)
  #   └─ other_collection (NOT included)
  #       ├─ stray_work                       (included individually)
  #       └─ linked_work                      (linked member of `collection`)

  describe 'contents resolution' do
    let(:reader_group) { 'northeastern:drs:test-readers' }

    let!(:community)        { Atlas.persister.save(resource: Community.new) }
    let!(:collection)       { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
    let!(:nested)           { Atlas.persister.save(resource: Collection.new(a_member_of: collection.id)) }
    let!(:other_collection) { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }

    let!(:nested_work) do
      Atlas.persister.save(resource: Work.new(a_member_of: nested.id, read_groups: ['public']))
    end
    let!(:work_in_collection) do
      Atlas.persister.save(resource: Work.new(a_member_of: collection.id, read_groups: ['public']))
    end
    let!(:private_work) do
      Atlas.persister.save(resource: Work.new(a_member_of: collection.id, read_groups: [reader_group]))
    end
    let!(:tombstoned_work) do
      Atlas.persister.save(resource: Work.new(a_member_of: collection.id, read_groups: ['public'],
                                              tombstoned: true))
    end
    let!(:excluded_work) do
      Atlas.persister.save(resource: Work.new(a_member_of: collection.id, read_groups: ['public']))
    end
    let!(:stray_work) do
      Atlas.persister.save(resource: Work.new(a_member_of: other_collection.id, read_groups: ['public']))
    end
    let!(:linked_work) do
      Atlas.persister.save(resource: Work.new(a_member_of:        other_collection.id,
                                              a_linked_member_of: [collection.id],
                                              read_groups:        ['public']))
    end

    let(:compilation) do
      create_compilation(curator).tap do |c|
        c.collection_inclusions.create!(resource_noid: collection.noid)
        c.work_inclusions.create!(resource_noid: stray_work.noid)
        c.exclusions.create!(resource_noid: excluded_work.noid)
      end
    end
    let(:id) { compilation.noid }

    path '/compilations/{id}/contents' do
      parameter name: :id, in: :path, type: :string, description: 'Compilation NOID'

      get 'Resolve a compilation into its current contents' do
        tags 'Compilations'
        produces 'application/json'
        description <<~D
          Resolves the recipe against the live index: works beneath any
          included Collection (transitively, linked members included), plus
          individually included works, minus set-asides, minus tombstoned
          works — gated to what the caller may discover (public + the
          caller's groups; admins see everything; same semantics as
          Cerberus gated discovery). Solr-side pagination via `page` /
          `per_page` (default 25, capped at 100).
        D
        security [{ BearerAuth: [], NuidHeader: [] }]
        parameter name: :Authorization, in: :header, type: :string, required: false
        parameter name: :User, in: :header, type: :string, required: false
        parameter name: :page, in: :query, type: :integer, required: false
        parameter name: :per_page, in: :query, type: :integer, required: false

        response '200', 'union minus exclusions, ACL-gated (owner with read group)' do
          schema '$ref' => '#/components/schemas/CompilationContents'
          let(:Authorization) { auth_header }
          let(:User) { "NUID #{curator.nuid}" }
          let(:page) { nil }
          let(:per_page) { nil }
          run_test! do |response|
            payload = JSON.parse(response.body)
            noids = payload['contents'].pluck('noid')

            expect(noids).to contain_exactly(
              nested_work.noid,        # transitive: under a nested sub-collection
              work_in_collection.noid, # direct member of the included collection
              private_work.noid,       # visible via the curator's read group
              stray_work.noid,         # individually added
              linked_work.noid         # linked member of the included collection
            )
            expect(noids).not_to include(excluded_work.noid, tombstoned_work.noid)
            expect(payload.dig('pagination', 'total')).to eq(5)

            digest = payload['contents'].first
            expect(digest['klass']).to eq('Work')
            expect(digest).to have_key('title')
            expect(digest).to have_key('thumbnail')
          end
        end

        response '200', 'guest reads a public set (the CERES case) — private works hidden' do
          schema '$ref' => '#/components/schemas/CompilationContents'
          let(:Authorization) { nil }
          let(:User) { nil }
          let(:page) { nil }
          let(:per_page) { nil }
          before { compilation.tap { |c| c.publicize && c.save! } }
          run_test! do |response|
            payload = JSON.parse(response.body)
            noids = payload['contents'].pluck('noid')

            expect(noids).to contain_exactly(
              nested_work.noid, work_in_collection.noid,
              stray_work.noid, linked_work.noid
            )
            expect(noids).not_to include(private_work.noid)
            expect(payload.dig('pagination', 'total')).to eq(4)
          end
        end

        response '200', 'pagination envelope (Solr-side start/rows)' do
          schema '$ref' => '#/components/schemas/CompilationContents'
          let(:Authorization) { auth_header }
          let(:User) { "NUID #{curator.nuid}" }
          let(:page) { 2 }
          let(:per_page) { 2 }
          run_test! do |response|
            payload = JSON.parse(response.body)
            expect(payload['contents'].length).to eq(2)
            expect(payload['pagination'])
              .to eq('total' => 5, 'page' => 2, 'per_page' => 2, 'pages' => 3)
          end
        end

        response '403', 'guest cannot resolve a private set' do
          let(:Authorization) { nil }
          let(:User) { nil }
          let(:page) { nil }
          let(:per_page) { nil }
          run_test!
        end

        response '404', 'unknown noid' do
          let(:id) { 'nope404' }
          let(:Authorization) { auth_header }
          let(:User) { "NUID #{curator.nuid}" }
          let(:page) { nil }
          let(:per_page) { nil }
          run_test!
        end
      end
    end
  end
end
