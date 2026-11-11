# frozen_string_literal: true

# The pass of OpenapiContract.finish that drops the schemas a document's own
# operations never reach. docs/openapi.md explains why.
module OpenapiSchemaPruning
  module_function

  # Both documents start from the whole schema map, so each keeps only the
  # schemas its own operations reach. Otherwise the public document would
  # publish the shapes of the internal operations it leaves out.
  def apply!(doc)
    schemas = doc.dig('components', 'schemas') || {}
    queue   = schema_refs(doc['paths']) + schema_refs(doc.dig('components', 'responses'))
    used    = Set.new
    while (name = queue.shift)
      queue.concat(schema_refs(schemas[name])) if used.add?(name)
    end
    schemas.select! { |name, _| used.include?(name) }
  end

  def schema_refs(node)
    case node
    when Hash  then node.flat_map { |key, value| key == '$ref' ? schema_ref_name(value) : schema_refs(value) }
    when Array then node.flat_map { |value| schema_refs(value) }
    else []
    end
  end

  def schema_ref_name(ref)
    ref.to_s.start_with?('#/components/schemas/') ? [ref.delete_prefix('#/components/schemas/')] : []
  end
end
