# frozen_string_literal: true

require 'swagger_helper'

# Default request auth is a signed admin assertion (manage :all), so the happy
# paths exercise the write surface without extra setup; the :standard 403 case
# overrides Authorization to prove the :system/admin gate.
RSpec.describe 'People', type: :request do
  let(:community) { CommunityCreator.call }

  let!(:jane) { PersonCreator.call(nuid: '001234567', display_name: 'Jane Doe', orcid: '0000-0002-1825-0097') }

  after { Atlas.persister.wipe! }

  path '/people' do
    get 'List or batch-resolve people' do
      tags 'People'
      produces 'application/json'
      description <<~DESC
        Without params: a paginated list of all Persons (`?page`, `?per_page`) —
        the NOID-keyed People-index source; each row carries the NOID (public
        address) plus the server-side nuid. With `?nuids=a,b,c`: batch-resolve to
        the authoritative display_name (supersedes the SSO users directory's
        name), dropping unresolved nuids — page size follows the match count.
      DESC
      parameter name: :nuids, in: :query, type: :string, required: false,
                description: 'Comma-separated NUIDs to batch-resolve'
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: "Page size (capped at #{LazyPagination::MAX_PER_PAGE})"

      response '200', 'paginated list' do
        let(:nuids) { nil }
        let(:page) { nil }
        let(:per_page) { nil }
        schema '$ref' => '#/components/schemas/PeopleIndex'
        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['people'].map { |p| p['person']['nuid'] }).to include('001234567')
          expect(body['pagination']).to be_present
        end
      end

      response '200', 'per_page caps the page size' do
        let!(:bob) { PersonCreator.call(nuid: '007654321', display_name: 'Bob Roe') }
        let(:nuids) { nil }
        let(:page) { 1 }
        let(:per_page) { 1 }
        schema '$ref' => '#/components/schemas/PeopleIndex'
        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['people'].size).to eq(1)
          expect(body['pagination']['items']).to eq(1)
        end
      end

      response '200', 'batch resolve by nuids (no pagination)' do
        let!(:bob) { PersonCreator.call(nuid: '007654321', display_name: 'Bob Roe') }
        let(:nuids) { '001234567,007654321,000000000' }
        let(:page) { nil }
        let(:per_page) { nil }
        schema '$ref' => '#/components/schemas/PeopleIndex'
        run_test! do |response|
          body = JSON.parse(response.body)
          names = body['people'].map { |p| p['person']['display_name'] }
          # No truncation despite pagination — page size follows match count.
          expect(names).to contain_exactly('Jane Doe', 'Bob Roe')
        end
      end
    end

    post 'Create a person (system/admin)' do
      tags 'People'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Creates a neutral curatorial identity. One Person per NUID — a duplicate
        NUID is a 409. System/admin only; a non-privileged caller receives 403.
      DESC
      parameter name: :Authorization, in: :header, type: :string, required: false
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          nuid:         { type: :string },
          display_name: { type: :string },
          bio:          { type: :string },
          orcid:        { type: :string }
        },
        required:   %w[nuid display_name]
      }

      response '201', 'created' do
        let(:Authorization) { "Bearer #{DefaultAuthHeaders.admin_assertion}" }
        let(:body) { { nuid: '009998888', display_name: 'New Person' } }
        schema '$ref' => '#/components/schemas/Person'
        run_test! do |response|
          person = JSON.parse(response.body)['person']
          expect(person).to include('nuid' => '009998888', 'display_name' => 'New Person')
          # The personal root is minted eagerly and surfaced as a NOID.
          expect(person['personal_root_id']).to be_present
          # Create emits a structural audit row for the Person.
          expect(AuditEvent.where(action: 'create', resource_type: 'Person')).to exist
        end
      end

      response '409', 'duplicate nuid' do
        let(:Authorization) { "Bearer #{DefaultAuthHeaders.admin_assertion}" }
        let(:body) { { nuid: '001234567', display_name: 'Dupe' } }
        run_test! do |response|
          expect(JSON.parse(response.body)['code']).to eq('duplicate_nuid')
        end
      end

      response '403', 'non-system/admin caller is rejected' do
        let!(:librarian) do
          User.create!(email: 'lib@example.edu', password: SecureRandom.hex(16),
                       nuid: '005550000', role: :standard)
        end
        let(:Authorization) { "Bearer #{DefaultAuthHeaders.assertion_for('005550000')}" }
        let(:body) { { nuid: '004443333', display_name: 'Nope' } }
        run_test!
      end
    end
  end

  path '/people/{id}' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the person'

    get 'Fetch a person by NOID' do
      tags 'People'
      produces 'application/json'

      response '200', 'person found' do
        let(:id) { jane.noid }
        schema '$ref' => '#/components/schemas/Person'
        run_test! do |response|
          person = JSON.parse(response.body)['person']
          expect(person['id']).to eq(jane.noid)
          expect(person['display_name']).to eq('Jane Doe')
          # NUID stays in the (server-side) response body, just not in the URL.
          expect(person['nuid']).to eq('001234567')
        end
      end

      response '404', 'unknown noid' do
        let(:id) { 'does-not-exist' }
        run_test!
      end
    end

    patch 'Edit authority fields (system/admin)' do
      tags 'People'
      consumes 'application/json'
      produces 'application/json'
      description 'Librarian edits to display_name/bio/orcid. NUID is immutable and not patchable.'
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          display_name: { type: :string },
          bio:          { type: :string },
          orcid:        { type: :string }
        }
      }

      response '200', 'updated' do
        let(:id) { jane.noid }
        let(:body) { { display_name: 'Jane A. Doe', bio: 'Researcher' } }
        schema '$ref' => '#/components/schemas/Person'
        run_test! do |response|
          person = JSON.parse(response.body)['person']
          expect(person).to include('display_name' => 'Jane A. Doe', 'bio' => 'Researcher')
        end
      end

      response '404', 'unknown noid' do
        let(:id) { 'does-not-exist' }
        let(:body) { { display_name: 'X' } }
        run_test!
      end
    end
  end

  path '/people/{id}/affiliations' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the person'

    post 'Add a community affiliation (audited, system/admin)' do
      tags 'People'
      consumes 'application/json'
      produces 'application/json'
      description 'Idempotent. Emits an add_affiliation audit event.'
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: { community_id: { type: :string, description: 'NOID of the community' } },
        required:   %w[community_id]
      }

      response '200', 'affiliation added' do
        let(:id) { jane.noid }
        let(:body) { { community_id: community.noid } }
        schema '$ref' => '#/components/schemas/Person'
        run_test! do |response|
          expect(JSON.parse(response.body)['person']['affiliated_community_ids']).to eq([community.noid])
          expect(AuditEvent.where(action: 'add_affiliation', resource_id: jane.id.to_s)).to exist
        end
      end

      response '422', 'unknown community' do
        let(:id) { jane.noid }
        let(:body) { { community_id: 'does-not-exist' } }
        run_test! do |response|
          expect(JSON.parse(response.body)['code']).to eq('unknown_community')
        end
      end
    end
  end

  path '/people/{id}/affiliations/{community_id}' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the person'
    parameter name: :community_id, in: :path, type: :string

    delete 'Remove a community affiliation (audited, system/admin)' do
      tags 'People'
      produces 'application/json'
      description 'Tolerant — removing an absent affiliation is a no-op. Emits a remove_affiliation audit event.'

      response '200', 'affiliation removed' do
        let(:id) { jane.noid }
        let(:community_id) { community.noid }
        before do
          jane.affiliated_community_ids = [community.id]
          Atlas.persister.save(resource: jane)
        end
        schema '$ref' => '#/components/schemas/Person'
        run_test! do |response|
          expect(JSON.parse(response.body)['person']['affiliated_community_ids']).to eq([])
        end
      end
    end
  end
end
