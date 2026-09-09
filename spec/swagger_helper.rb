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

          Every request resolves its principal from the bearer token. Four
          credentials are recognised:

          - **No token** — the guest principal. Most reads fall through here.
          - **A Cerberus signed assertion** (ES256, `iss=cerberus`,
            `aud=atlas`) — the relay path. Identity is the proven `sub`;
            acting-as rides a signed `obo` claim, never a header.
          - **A devise-JWT** minted by `POST /nuid` — the standalone path, for
            a librarian's own scripts. Identity is the token's, so the `User`
            header is ignored.
          - **The system token** plus a `User: NUID <system>` header — the
            backend-to-backend path, valid only as the system principal.

          Anything else is a `401`. Endpoints that need more than the read
          floor declare it explicitly below.

          ### Errors

          Failures carry a JSON body with an `error` key, and several are
          machine-readable discriminators a client is expected to branch on —
          `read_only_mode` on the maintenance window, `stale_resource` on an
          optimistic-lock conflict, `fixity_mismatch` on a rejected upload.

          Two shapes are not documented per operation, because they apply to
          all of them. **Any endpoint can answer `5xx`**, and a proxy in front
          of Atlas can answer `502` / `504` with a body that is not JSON at
          all — see the `ServerError` response below. And **any write can
          answer `503` with `error: "read_only_mode"` and a `Retry-After`
          header** while the repository-wide read-only window is open. A
          client must consult the status before it reads the body; the
          `Retry-After` on that `503` is measured in minutes, so it is a
          "come back later", not a "try again now".
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
            description: 'A Cerberus signed assertion, a devise-jwt user token, or the Cerberus system token. All three are accepted; ' \
                         'see the Authentication note above for which identity each one proves.'
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
                         'Honoured only on the system-token path, which is backend-to-backend; human acting-as rides a signed `obo` claim ' \
                         'inside the Cerberus assertion instead, so the target cannot be forged onto a stolen credential. ' \
                         'The header names the user a write is attributed to: on a create the resulting resource reads as a pure deposit by the ' \
                         'target — `depositor` = target, `proxy_uploader` left null — with the operator recorded only in the AuditEvent. ' \
                         'Presented on any other path it is rejected (403), admin or not.'
          }
        },
        # Referenced from the Errors note in `info.description` rather than
        # from an operation: rswag emits a response only where a request spec
        # asserts one, and a 5xx is not something a spec can provoke per path.
        # Naming the shape once is still worth it — a client author reading
        # this document otherwise has no signal that a non-JSON error body is
        # possible.
        responses:       {
          ServerError: {
            description: 'Atlas, or a proxy in front of it, failed to serve the request. ' \
                         'Applies to every operation. Atlas\'s own 5xx carries a JSON ' \
                         '`{ "error": … }` body; a proxy\'s 502/504 may carry HTML or ' \
                         'plain text, so a client must key on the status rather than ' \
                         'parsing the body first.',
            content:     {
              'application/json' => {
                schema: {
                  type:       :object,
                  properties: { error: { type: :string } }
                }
              }
            }
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
