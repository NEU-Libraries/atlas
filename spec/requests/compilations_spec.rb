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
                 nuid: '000000002', role: :standard)
  end
  let!(:rando) do
    User.create!(email: 'rando@example.com', password: SecureRandom.hex(16),
                 nuid: '000000003', role: :standard)
  end
  let!(:admin) do
    User.create!(email: 'admin@example.com', password: SecureRandom.hex(16),
                 nuid: '000000004', role: :admin)
  end

  let(:cerberus_token) { 'test-cerberus-token' }
  let(:auth_header)    { "Bearer #{cerberus_token}" }

  before do
    allow(Rails.application.credentials)
      .to receive(:cerberus_token).and_return(cerberus_token)
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
        There is no public browse endpoint.
      D
      security [{ BearerAuth: [], NuidHeader: [] }]
      parameter name: :Authorization, in: :header, type: :string, required: false
      parameter name: :User, in: :header, type: :string, required: false
      parameter name: :owner, in: :query, type: :string, required: false,
                description: 'NUID whose Sets to list (admin-only); defaults to the caller'

      response '200', 'own compilations listed' do
        schema '$ref' => '#/components/schemas/CompilationsIndex'
        let(:Authorization) { auth_header }
        let(:User)  { "NUID #{curator.nuid}" }
        let(:owner) { nil }
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

      response '403', 'cross-owner listing as a non-admin' do
        let(:Authorization) { auth_header }
        let(:User)  { "NUID #{rando.nuid}" }
        let(:owner) { curator.nuid }
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
end
