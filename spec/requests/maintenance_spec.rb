# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Maintenance', type: :request do
  path '/maintenance' do
    get 'Read the repository-wide read-only window' do
      tags 'Maintenance'
      operationId 'maintenance_show'
      produces 'application/json'
      description <<~D
        The state of the repository-wide read-only window. On the authenticated
        read floor, and answered even while the window is open — a client that
        could not read the flag could not honour it.

        While `read_only` is true every write-shaped action is refused with a
        `503` carrying `error: "read_only_mode"` and a `Retry-After` header.
      D

      response '200', 'window state' do
        schema '$ref' => '#/components/schemas/MaintenanceMode'
        run_test! do |response|
          expect(JSON.parse(response.body)['read_only']).to be(false)
        end
      end
    end

    put 'Open or close the repository-wide read-only window' do
      tags 'Maintenance'
      operationId 'maintenance_update'
      consumes 'application/json'
      produces 'application/json'
      description <<~D
        Open (`read_only: true`) or close (`read_only: false`) the window.
        Restricted to the system principal and admins.

        `source` names which door is acting. A `deploy` close is refused —
        silently, leaving the window standing and reporting the unchanged state —
        when an `operator` opened the window, so a deploy that finishes cannot
        close a window a human opened by hand. An `operator` close clears either.

        This is the one action the read-only floor exempts; an open window has to
        stay closable.
      D
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          read_only:   { type: :boolean },
          source:      { type: :string, enum: %w[operator deploy] },
          message:     { type: :string },
          retry_after: { type: :integer }
        },
        required:   %w[read_only]
      }

      response '200', 'window opened' do
        schema '$ref' => '#/components/schemas/MaintenanceMode'
        let(:body) { { read_only: true, source: 'operator', message: 'Back at 10:00' } }
        run_test! do |response|
          parsed = JSON.parse(response.body)
          expect(parsed['read_only']).to be(true)
          expect(parsed['source']).to eq('operator')
          expect(parsed['message']).to eq('Back at 10:00')
          expect(parsed['since']).to be_present
        end
      end
    end
  end

  path '/reset' do
    get 'Reset development/test state' do
      tags 'Maintenance'
      operationId 'maintenance_reset'
      description <<~D
        Wipes the database and Solr index. Refuses to run in production.

        **Internal endpoint — do not call from clients.** Used by test
        harnesses and developer-environment seeders.
      D

      response '204', 'state reset' do
        run_test!
      end
    end
  end
end
