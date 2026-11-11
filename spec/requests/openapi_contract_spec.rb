# frozen_string_literal: true

require 'rails_helper'

# The generated documents attach shared responses to operations
# (OpenapiContract.finish) without a spec per operation. This holds them to
# the two that can be proved on every route: a bad token answers 401, and an
# unknown identifier answers 404. It reads the committed files, which CI
# regenerates and compares, so the list it walks is the list a client sees.
# The shared 403 rests on check_authorization and the access matrices.
RSpec.describe 'The OpenAPI documents' do
  documents = %w[public internal].index_with do |name|
    YAML.load_file(Rails.root.join("openapi/#{name}/openapi.yaml"))
  end

  shared = lambda do |code, ref|
    documents.flat_map do |name, doc|
      OpenapiContract.operations(doc).filter_map do |template, verb, op|
        [name, template, verb] if op.dig('responses', code, '$ref') == ref
      end
    end
  end

  # Any value the route's constraints accept.
  def sample_path(template, id)
    template.gsub('{version_id}', 'v1').gsub(/\{\w+\}/, id)
  end

  describe 'the shared 401', default_auth: false do
    shared.call('401', OpenapiContract::UNAUTHORIZED_REF).each do |name, template, verb|
      it "#{name}: #{verb.upcase} #{template} answers a bad token with 401" do
        process(verb.to_sym, sample_path(template, 'nonexistent'),
                headers: { 'Authorization' => 'Bearer not-a-token' })

        expect(response).to have_http_status(:unauthorized)
        expect(JSON::Validator.fully_validate(OpenapiSchemas.error, response.body)).to be_empty
      end
    end
  end

  # As the suite's default admin, so no read gate answers first.
  describe 'the shared 404' do
    shared.call('404', OpenapiContract::NOT_FOUND_REF).each do |name, template, verb|
      it "#{name}: #{verb.upcase} #{template} answers an unknown identifier with 404" do
        process(verb.to_sym, sample_path(template, 'nonexistent'),
                params: '{}', headers: { 'CONTENT_TYPE' => 'application/json' })

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  it 'names every operation once across both documents' do
    ids = documents.values.flat_map { |doc| OpenapiContract.operations(doc).map { |_, _, op| op['operationId'] } }

    expect(ids).to all(be_present)
    expect(ids.tally.select { |_, n| n > 1 }).to be_empty
  end
end
