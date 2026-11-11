# frozen_string_literal: true

# Which 4xx responses carry an Error body, decided once and applied twice: to
# each generated document by OpenapiContract.finish, and to every 4xx a request
# spec receives, by OpenapiResponseHooks. docs/openapi.md explains the rule.
module OpenapiErrorBodies
  NO_BODY    = 'x-atlas-no-body'
  ERROR_BODY = 'x-atlas-error-body'

  # Atlas answers a missing resource with a bare `head :not_found`, and a bad
  # byte range with a bare 416. Every other 4xx carries an Error body.
  BODILESS_BY_DEFAULT = %w[404 416].freeze

  module_function

  # Whether a 4xx response carries an Error body: by default unless it is a
  # 404 or 416, and always when the spec declared a schema. A spec overrides
  # the default with `no_body` or `error_body` inside the response block.
  def error_body?(code, response, declared)
    return false if response[NO_BODY] || response[NO_BODY.to_sym]
    return true if declared || response[ERROR_BODY] || response[ERROR_BODY.to_sym]

    BODILESS_BY_DEFAULT.exclude?(code.to_s)
  end

  # A 410 can answer with the tombstoned resource's own record, or a stub of it,
  # rather than an Error; the spec declares those schemas, rswag validates the
  # body against them, and they are kept.
  def tombstone_record?(code, schema)
    return false unless code.to_s == '410' && schema.is_a?(Hash)

    ref = schema['$ref'] || schema[:$ref]
    (ref.present? && ref != OpenapiContract::ERROR_REF) || (schema['oneOf'] || schema[:oneOf]).present?
  end

  def document(code, response)
    return unless code.to_s.start_with?('4') && response.is_a?(Hash) && !response.key?('$ref')

    content = error_content(code, response, response['content'] || {})
    content ? response['content'] = content : response.delete('content')
    response.except!(NO_BODY, ERROR_BODY)
  end

  def error_content(code, response, content)
    schemas = content.values.pluck('schema')
    record = schemas.find { |schema| tombstone_record?(code, schema) }
    return { 'application/json' => { 'schema' => record } } if record
    return unless error_body?(code, response, schemas.any?)

    { 'application/json' => { 'schema' => { '$ref' => OpenapiContract::ERROR_REF } } }
  end

  # The runtime half of document: every 4xx a request spec receives
  # must be what the document says it is.
  def check(metadata, response)
    meta = metadata[:response]
    code = meta[:code].to_s
    return unless code.start_with?('4') && !tombstone_record?(code, meta[:schema])

    problem = if error_body?(code, meta, meta[:schema].present?)
                error_body_problem(response)
              elsif response.body.present?
                'is documented with no body; call error_body in the response block, or declare its schema'
              end
    raise "#{code} #{problem}: #{response.media_type} #{response.body.to_s[0, 300]}" if problem
  end

  def error_body_problem(response)
    return 'is documented with an Error body, but has none' if response.body.blank?
    return 'is documented as application/json' unless response.media_type == 'application/json'

    errors = JSON::Validator.fully_validate(json_schema(OpenapiSchemas.error), response.body)
    "does not match the Error schema: #{errors.join('; ')}" if errors.any?
  end

  # OpenAPI's `nullable` is not JSON Schema; json-schema ignores it.
  def json_schema(node)
    return node.map { |value| json_schema(value) } if node.is_a?(Array)
    return node unless node.is_a?(Hash)

    out = node.except(:nullable).transform_values { |value| json_schema(value) }
    node[:nullable] ? out.merge(type: [node[:type], 'null']) : out
  end
end
