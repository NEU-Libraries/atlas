# frozen_string_literal: true

require 'swagger_helper'

# The response shape, which drives the OpenAPI entry. Who may call it is
# index_read_gate_spec.rb.
RSpec.describe 'Solr documents', type: :request do
  let(:community)  { public_community! }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  after { Atlas.persister.wipe! }

  path '/resources/{id}/solr' do
    get "An object's Solr document" do
      tags 'Resources'
      produces 'application/json'
      description <<~DESC
        The object's Solr document exactly as Solr stores it, for debugging the
        index. Admins and delegated admins only; a delegated admin must also be
        able to read the object.

        Fields that are searched but not stored never appear:
        `descriptive_keywords_tesim`, `title_stem_tesim`,
        `description_stem_tesim` and `name_variant_teim`, among others. Their
        absence is not a fault. `GET /resources/{id}/search_explanation` shows
        what they match.

        404 for an unknown NOID and for a Set, which Atlas does not index. 404
        with `error: not_indexed` when the object exists but Solr holds no
        document for it; `POST /resources/{id}/reindex` is the fix.
      DESC
      parameter name: :id, in: :path, type: :string, description: 'NOID'

      response '200', 'the Solr document' do
        schema '$ref' => '#/components/schemas/IndexDocument'
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }

        run_test! do |response|
          body = response.parsed_body
          expect(body['noid']).to eq(work.noid)
          expect(body['document']).to include('id' => work.id.to_s, 'alternate_ids_ssim' => ["id-#{work.noid}"],
                                              'internal_resource_tesim' => ['Work'])
          expect(body['document']).not_to have_key('score')
        end
      end

      response '404', 'unknown NOID' do
        let(:id) { 'nosuchnoid' }

        run_test!
      end

      response '404', 'a Set, which is not indexed' do
        let(:id) { Compilation.create!(title: 'A Set', depositor: '000000004').noid }

        run_test!
      end

      response '404', 'the object has no Solr document' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }

        before { Atlas.index_adapter.persister.delete(resource: work) }

        run_test! do |response|
          expect(response.parsed_body).to eq('error' => 'not_indexed')
        end
      end
    end
  end
end
