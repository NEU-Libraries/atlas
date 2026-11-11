# frozen_string_literal: true

require 'rails_helper'

# The generated documents attach the shared 401 to every operation that
# accepts a credential (OpenapiContract.finish), without a spec per operation.
# This holds them to it: every such operation, in both documents, answers an
# unrecognised token with a 401 whose body is the Error schema. It reads the
# committed files, which CI regenerates and compares, so the list it walks is
# the list a client sees.
RSpec.describe 'The OpenAPI documents', default_auth: false do
  documents = %w[public internal].index_with do |name|
    YAML.load_file(Rails.root.join("openapi/#{name}/openapi.yaml"))
  end

  documents.each do |name, doc|
    OpenapiContract.operations(doc).each do |template, verb, op|
      next unless op.dig('responses', '401', '$ref') == OpenapiContract::UNAUTHORIZED_REF

      it "#{name}: #{verb.upcase} #{template} answers a bad token with 401" do
        # Any value the route accepts: require_auth answers before a lookup.
        path = template.gsub('{version_id}', 'v1').gsub(/\{\w+\}/, 'nonexistent')
        process(verb.to_sym, path, headers: { 'Authorization' => 'Bearer not-a-token' })

        expect(response).to have_http_status(:unauthorized)
        expect(JSON::Validator.fully_validate(OpenapiSchemas.error, response.body)).to be_empty
      end
    end
  end

  it 'names every operation once across both documents' do
    ids = documents.values.flat_map { |doc| OpenapiContract.operations(doc).map { |_, _, op| op['operationId'] } }

    expect(ids).to all(be_present)
    expect(ids.tally.select { |_, n| n > 1 }).to be_empty
  end
end
