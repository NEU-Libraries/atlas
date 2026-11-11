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

  # The first entry is the default for a spec that names no document. Tag an
  # operator or backend operation with `openapi_spec: OpenapiDocument::INTERNAL`.
  config.openapi_specs = OpenapiDocument.specs
end

# Hand-write a multipart/form-data requestBody for an operation. rswag-specs
# cannot describe a multi-field form: its formatter takes the FIRST formData
# parameter that carries a schema and makes that one field's schema the whole
# body, discarding every sibling. So declare the comprehensive doc shape here,
# from inside an operation block.
#
# Pair it with a bare `parameter name: :x, in: :formData, required: false` per
# field. Bare is load-bearing — rswag upgrades a `type:` shorthand into a
# `schema:`, which is exactly what makes the formatter select the parameter
# and clobber this body. Runtime serialization needs neither: Rack::Test reads
# the value from the example's `let` by parameter name alone, and the field's
# type and description belong in the properties hash passed here.
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

      # Inside a verb block: this operation belongs in the internal document. A
      # whole path can pass `openapi_spec: OpenapiDocument::INTERNAL` instead.
      # Set before the response blocks, which copy their parent's metadata.
      def internal_operation!
        metadata[:openapi_spec] = OpenapiDocument::INTERNAL
      end

      # Inside a verb block: this operation's path parameter is not a lookup
      # that answers 404 for an unknown value, such as a list that is empty for
      # it, or a find-or-create. The formatter then leaves out the shared 404.
      def no_not_found
        metadata[:operation][OpenapiContract::NO_NOT_FOUND] = true
      end

      # Inside a response block on a route that also serves XML or HTML: the
      # schema of its JSON body alone, which rswag cannot express.
      def json_schema(name)
        metadata[:response][OpenapiJsonBodies::KEY] = name.to_s
      end

      # Inside a response block: the body is a file's bytes, whatever their
      # type. Not a `schema`, which rswag would validate as JSON.
      def binary_body
        metadata[:response][OpenapiJsonBodies::BINARY] = true
      end

      # Inside a response block: this 4xx answers with no body, against the
      # default that only 404 and 416 are bare. See docs/openapi.md.
      def no_body
        metadata[:response][OpenapiErrorBodies::NO_BODY] = true
      end

      # Inside a response block: this 404 or 416 carries an Error body.
      def error_body
        metadata[:response][OpenapiErrorBodies::ERROR_BODY] = true
      end

      # The paging parameters of a list. Pass per_page: true only where the
      # action reads it; LazyPagination caps it at MAX_PER_PAGE. A search-backed
      # list returns SearchPagination, which has no `next`, so it says so.
      PAGE_STOP = {
        pagy:   'Follow `pagination.next` until it is null.',
        search: 'Stop when `pagination.page` reaches `pagination.pages`.'
      }.freeze

      def paginated(per_page: false, shape: :pagy)
        parameter name: :page, in: :query, required: false, schema: { type: :integer, minimum: 1 },
                  description: "The page to return, from 1. #{PAGE_STOP.fetch(shape)} A page below 1 is " \
                               'page 1, and a page past the end is empty.'
        return unless per_page

        parameter name: :per_page, in: :query, required: false,
                  schema:      { type: :integer, minimum: 1, maximum: LazyPagination::MAX_PER_PAGE },
                  description: "Items per page, at most #{LazyPagination::MAX_PER_PAGE}. A value that is not a " \
                               'positive number gives the default.'
      end
    end
  end
end

# The `origin` formData field, declared identically on every MODS PATCH
# (Works, Collections, Communities). One constant so the three operations
# cannot drift apart in the generated OpenAPI document.
ORIGIN_PARAM_DESCRIPTION = <<~TEXT.squish
  Free-text tag naming the editing surface that produced this MODS upload
  (Cerberus sends `metadata_form`, `advanced_form` or `xml_editor`). Recorded
  verbatim on the audit event beside `source`, truncated at 64 characters.
  Omit it and the event carries no origin, which is what every event recorded
  before this field looks like.
TEXT
