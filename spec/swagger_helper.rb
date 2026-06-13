# frozen_string_literal: true

require 'rails_helper'

# rswag-specs uses json-schema, which still routes through MultiJSON by
# default. MultiJSON support is deprecated upstream — opt out so we use the
# stdlib JSON parser directly.
require 'json-schema'
JSON::Validator.use_multi_json = false

RSpec.configure do |config|
  config.openapi_root = Rails.root.join('openapi').to_s
  config.openapi_format = :yaml
  # Strict validation is the drift detector: any field present in the
  # response but missing from the schema (or vice versa) fails the spec.
  config.openapi_strict_schema_validation = true

  config.openapi_specs = {
    'openapi.yaml' => {
      openapi:    '3.0.3',
      info:       {
        title:       'Atlas API',
        version:     '1',
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
      servers:    [
        {
          url:       '{scheme}://{host}',
          variables: {
            scheme: { default: 'https', enum: %w[https http] },
            host:   { default: 'atlas.library.northeastern.edu' }
          }
        }
      ],
      tags:       [
        { name: 'Communities' },
        { name: 'Collections' },
        { name: 'Works' },
        { name: 'FileSets' },
        { name: 'Files' },
        { name: 'Resources' },
        { name: 'Compilations' },
        { name: 'User' },
        { name: 'Maintenance' }
      ],
      components: {
        securitySchemes: {
          BearerAuth:       {
            type:        :http,
            scheme:      :bearer,
            description: 'Cerberus system token or a devise-jwt user token. Both are accepted.'
          },
          NuidHeader:       {
            type:        :apiKey,
            in:          :header,
            name:        'User',
            description: 'NUID identity asserted by Cerberus, in the form `NUID <nuid>`. Required when calling with the system token to act as a user.'
          },
          OnBehalfOfHeader: {
            type:        :apiKey,
            in:          :header,
            name:        'On-Behalf-Of',
            description: 'Acting-as attribution target, in the form `NUID <nuid>`. ' \
                         'Sent on writes during an acting-as session: the `User` header (the operator) authorizes the request and must be an admin; ' \
                         'this header names the user the write is attributed to. On a create, the resulting resource reads as a pure deposit by the ' \
                         'target — `depositor` = target, `proxy_uploader` left null — with the operator recorded only in the AuditEvent. ' \
                         'A non-admin operator presenting this header is rejected (403).'
          }
        },
        schemas:         OpenapiSchemas.all
      }
    }
  }
end

# Hand-write a multipart/form-data requestBody for an operation. rswag-specs
# generates a buggy single-field requestBody when several `parameter in:
# :formData` declarations are present (it picks the first param's schema as
# the entire body), so use this from inside an operation block to declare
# the comprehensive doc shape. Pair with per-field `parameter in: :formData`
# entries (no `schema:` on those, only `type:`), which drive runtime
# multipart serialization in Rack::Test.
module Rswag
  module Specs
    module ExampleGroupHelpers
      def multipart_request_body(properties, required: [], description: nil)
        schema = { type: :object, properties: properties }
        schema[:required] = required.map(&:to_s) unless required.empty?
        body = {
          required: !required.empty?,
          content:  { 'multipart/form-data' => { schema: schema } }
        }
        body[:description] = description if description
        metadata[:operation][:requestBody] = body
      end
    end
  end
end
