# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'User', type: :request, default_auth: false do
  let!(:guest) do
    User.create!(
      email: 'guest@example.com',
      password: SecureRandom.hex(16),
      role: :guest
    )
  end

  path '/user' do
    get 'Current user details' do
      tags 'User'
      produces 'application/json'
      description <<~D
        Returns the user resolved from the request auth context. With no
        valid Bearer/NUID, falls through to the guest user record.
      D

      response '200', 'user returned' do
        schema '$ref' => '#/components/schemas/User'
        run_test!
      end
    end
  end

  path '/nuid' do
    post 'Mint a JWT for a NUID (system-only)' do
      tags 'User'
      consumes 'application/json'
      produces 'application/json'
      description <<~D
        System-only endpoint used by Cerberus to mint a per-user JWT.
        Requires the system Bearer token; non-system callers receive 403.
      D
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: { nuid: { type: :string } },
        required: %w[nuid]
      }

      response '403', 'caller is not the system user' do
        let(:body) { { nuid: '000000001' } }
        run_test!
      end
    end
  end

  path '/users/by_nuid/{nuid}' do
    put 'Find-or-create a user and replace their groups (system-only)' do
      tags 'User'
      consumes 'application/json'
      produces 'application/json'
      description <<~D
        System-only endpoint used by Cerberus on SSO callback. Idempotent
        on NUID; replaces (not merges) the supplied groups onto the user.
        Requires the system Bearer token (no `User:` header); non-system
        callers receive 403.
      D
      security [{ BearerAuth: [] }]
      parameter name: :nuid, in: :path, type: :string
      parameter name: :Authorization, in: :header, type: :string, required: false
      parameter name: :User, in: :header, type: :string, required: false,
                description: "Acting principal, e.g. \"NUID 000000000\" for the system user"
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          groups: { type: :array, items: { type: :string } },
          email: { type: :string },
          name: { type: :string }
        }
      }

      response '200', 'user upserted' do
        schema '$ref' => '#/components/schemas/ProvisionedUser'

        let!(:system_user) do
          User.create!(
            email:    'system@example.com',
            password: SecureRandom.hex(16),
            nuid:     '000000000',
            role:     :system
          )
        end
        let(:system_token) { 'test-system-token' }
        before do
          allow(Rails.application.credentials)
            .to receive(:cerberus_token).and_return(system_token)
        end
        let(:Authorization) { "Bearer #{system_token}" }
        let(:User) { "NUID #{system_user.nuid}" }
        let(:nuid) { '001234567' }
        let(:body) do
          {
            groups: ['northeastern:staff', 'drs:editors'],
            email: 'jane@example.edu',
            name: 'Jane Doe'
          }
        end
        run_test! do |response|
          payload = JSON.parse(response.body)
          expect(payload.dig('user', 'nuid')).to eq('001234567')
          expect(payload.dig('user', 'groups'))
            .to eq(['northeastern:staff', 'drs:editors'])
        end
      end

      response '403', 'caller is not the system user' do
        let(:nuid) { '001234567' }
        let(:Authorization) { nil }
        let(:body) { { groups: [] } }
        run_test!
      end
    end
  end
end
