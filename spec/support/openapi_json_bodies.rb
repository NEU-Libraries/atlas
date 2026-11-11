# frozen_string_literal: true

# The JSON body of a route that also serves XML or HTML. rswag gives one schema
# to every media type an operation produces, so such a route declares its JSON
# schema with `json_schema :Name` instead; the formatter puts it under the JSON
# media type alone, and every JSON body a spec receives is checked against it.
# docs/openapi.md explains the rule.
module OpenapiJsonBodies
  KEY = 'x-atlas-json-schema'

  module_function

  def document(response)
    return unless response.is_a?(Hash)

    name = response.delete(KEY)
    return unless name

    media = ((response['content'] ||= {})['application/json'] ||= {})
    media['schema'] = { '$ref' => "#/components/schemas/#{name}" }
  end

  def check(metadata, response)
    name = metadata[:response][KEY]
    return unless name && response.media_type == 'application/json'

    schema = root.merge('$ref' => "#/components/schemas/#{name}")
    errors = JSON::Validator.fully_validate(schema, response.body)
    raise "JSON body does not match #{name}: #{errors.join('; ')}" if errors.any?
  end

  # The component map, with OpenAPI's `nullable` spelled as JSON Schema, so a
  # `$ref` into it resolves the way the published document does.
  def root
    @root ||= { 'components' => { 'schemas' => OpenapiErrorBodies.json_schema(OpenapiSchemas.all) } }
  end
end
