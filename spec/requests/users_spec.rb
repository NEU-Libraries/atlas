# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'User', type: :request do
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
end
