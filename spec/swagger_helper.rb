# frozen_string_literal: true

require 'rails_helper'

RSpec.configure do |config|
  config.openapi_root = Rails.root.join('openapi').to_s
  config.openapi_format = :yaml
  # Strict validation is the drift detector: any field present in the
  # response but missing from the schema (or vice versa) fails the spec.
  config.openapi_strict_schema_validation = true

  config.openapi_specs = {
    'openapi.yaml' => {
      openapi: '3.0.3',
      info: {
        title: 'Atlas API',
        version: '1',
        description: <<~DESC
          Atlas is the Northeastern University Library digital repository API.

          Two consumption surfaces of this document:

          - Humans: Scalar UI at `/docs`
          - Machines (clients, agents, codegen): the canonical OpenAPI
            document is served at `/api-docs/openapi.yaml`.

          ### Authentication

          Most write endpoints require a Cerberus system bearer token plus a
          `User` header carrying the acting NUID. Read endpoints generally
          allow unauthenticated guest access. Endpoints that require auth
          declare it explicitly below.
        DESC
      },
      servers: [
        {
          url: '{scheme}://{host}',
          variables: {
            scheme: { default: 'https', enum: %w[https http] },
            host:   { default: 'atlas.library.northeastern.edu' }
          }
        }
      ],
      tags: [
        { name: 'Communities' },
        { name: 'Collections' },
        { name: 'Works' },
        { name: 'FileSets' },
        { name: 'Files' },
        { name: 'Resources' },
        { name: 'User' },
        { name: 'Maintenance' }
      ],
      components: {
        securitySchemes: {
          BearerAuth: {
            type: :http,
            scheme: :bearer,
            description: 'Cerberus system token or a devise-jwt user token. Both are accepted.'
          },
          NuidHeader: {
            type: :apiKey,
            in: :header,
            name: 'User',
            description: 'NUID identity asserted by Cerberus, in the form `NUID <nuid>`. Required when calling with the system token to act as a user.'
          }
        },
        schemas: OpenapiSchemas.all
      }
    }
  }
end
