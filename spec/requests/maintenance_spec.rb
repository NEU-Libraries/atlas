# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Maintenance', type: :request do
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
