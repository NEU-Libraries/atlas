# frozen_string_literal: true

# A response block's name is a test name; what a client reads for each status
# is the operation's `response_texts`. A declared status without one fails
# generation, so a test name is never published. docs/openapi.md explains it.
module OpenapiResponseTexts
  KEY = 'x-atlas-response-texts'

  module_function

  def apply!(doc)
    missing = OpenapiContract.operations(doc).flat_map do |template, verb, op|
      texts = op.delete(KEY) || {}
      op['responses'].filter_map do |code, response|
        next if response.key?('$ref')

        if texts[code]
          response['description'] = texts[code]
          next
        end
        "#{verb.upcase} #{template} #{code}"
      end
    end
    raise "No response_texts entry for: #{missing.join(', ')}" if missing.any?
  end
end
