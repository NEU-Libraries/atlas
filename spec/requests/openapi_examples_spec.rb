# frozen_string_literal: true

require 'rails_helper'

# Every recorded example is published in an OpenAPI document, so each one must
# be safe to publish and must still belong to an operation. Spectral's
# oas3-valid-media-example checks each one against its current schema; this
# checks what Spectral cannot. See docs/openapi.md.
# Skipped while bin/openapi-record runs: it empties the directory first, and
# these check the committed files, not a recording in progress.
RSpec.describe 'The recorded OpenAPI examples',
               skip: OpenapiExamples.recording? && 'recording examples' do
  files = OpenapiExamples::DIR.glob('*/*.json').sort

  documented = %w[public internal].flat_map do |name|
    doc = YAML.load_file(Rails.root.join("openapi/#{name}/openapi.yaml"))
    OpenapiContract.operations(doc).flat_map do |template, verb, op|
      op['responses'].keys.map { |code| OpenapiExamples.path_for(template, verb, code) }
    end
  end

  # Every string in a body, with the key it sits under.
  def self.strings(node, key = nil, &)
    case node
    when Hash   then node.each { |k, v| strings(v, k, &) }
    when Array  then node.each { |v| strings(v, key, &) }
    when String then yield(key, node)
    end
  end

  it 'has examples to check' do
    expect(files).not_to be_empty
  end

  files.each do |file|
    name = file.relative_path_from(OpenapiExamples::DIR).to_s

    describe name do
      body = JSON.parse(file.read)

      it 'belongs to a documented response' do
        expect(documented).to include(file)
      end

      it 'holds nothing that is not safe to publish' do
        problems = []
        self.class.strings(body) do |key, value|
          if OpenapiExamples::SECRET_KEYS.include?(key.to_s)
            problems << "#{key} is not redacted" unless value == OpenapiExamples::SECRET
            next
          end
          problems += value.scan(OpenapiExamples::EMAIL).grep_v(OpenapiExamples::EMAIL_PLACEHOLDER).map { "email #{it}" }
          problems += value.scan(OpenapiExamples::UUID).grep_v(OpenapiExamples::UUID_PLACEHOLDER).map { "uuid #{it}" }
          problems += value.scan(OpenapiExamples::NOID).grep_v(OpenapiExamples::NOID_PLACEHOLDER)
                           .reject { OpenapiExamples::PUBLIC_TOKENS.include?(it) }.map { "noid #{it}" }
          if value.match?(OpenapiExamples::DATETIME) && value != OpenapiExamples::TIMESTAMP
            problems << "timestamp #{value}"
          end
          problems += value.scan(OpenapiExamples::DATE_IN).reject { it == OpenapiExamples::DATE }.map { "date #{it}" }
          problems += value.scan(%r{https?://([^/:\s"]+)}).flatten.reject { |host| OpenapiExamples.publishable_host?(host) }
                           .map { "host #{it}" }
        end

        expect(problems).to be_empty, "#{name}: #{problems.uniq.join(', ')}. Re-record with RECORD_EXAMPLES=1."
      end
    end
  end
end
