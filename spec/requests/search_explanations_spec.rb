# frozen_string_literal: true

require 'swagger_helper'

# The response shape, which drives the OpenAPI entry. What the explanation says
# is spec/queries/search_explanation_query_spec.rb; who may call it is
# index_read_gate_spec.rb.
RSpec.describe 'Search explanations', type: :request do
  let(:community)  { public_community! }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work) do
    w = WorkCreator.call(parent_id: collection.noid)
    Work.find(w.noid).mods_xml = Rails.root.join('spec/fixtures/files/work-mods.xml').read
                                      .sub("What's New", 'Coastal Survey')
    Atlas.persister.save(resource: Work.find(w.noid))
  end

  after { Atlas.persister.wipe! }

  path '/resources/{id}/search_explanation' do
    get 'How the catalog search scores one object' do
      tags 'Resources'
      produces 'application/json'
      description <<~DESC
        Solr's own account of how the catalog search scores one Work, Collection
        or Community for `q`, whether it matches or not, for debugging search.
        Admins and delegated admins only; a delegated admin must also be able to
        read the object.

        `explanation` is Solr's structured `explainOther` tree, unchanged.
        `handler` is the search handler's `qf`, `pf`, `mm`, `tie` and `boost`,
        read from Solr. `hidden_by` names the always-on catalog filters that
        hide the object whatever it matches.

        `fields` has one entry per `qf` field. Each stored value that feeds the
        field is analysed against `q`, and its index tokens carry `match`.
        Offsets count UTF-16 code units, as Solr reports them. A field with no
        stored text says why in `reason`: `not_stored`, or `full_text`, whose
        matching passages are in `highlights`. A failed analysis is
        `analysis_failed`; the other fields are still returned.

        400 for a blank `q`. 404 for an unknown NOID, a Set or any other type;
        404 with `error: not_indexed` when Solr holds no document for the
        object. 502 when Solr does not answer.
      DESC
      parameter name: :id, in: :path, type: :string, description: 'NOID'
      parameter name: :q, in: :query, type: :string, required: true, description: 'The search words'

      let(:id) { work.noid }

      response '200', 'the object matches' do
        schema '$ref' => '#/components/schemas/SearchExplanation'
        let(:q) { 'coastal surveys' }

        run_test! do |response|
          body = response.parsed_body
          expect(body).to include('noid' => work.noid, 'q' => 'coastal surveys', 'matched' => true, 'hidden_by' => [])
          expect(body['score']).to be > 0
          expect(body.dig('handler', 'qf')).to include('title_tsim')
          expect(body['fields'].pluck('field')).to eq(body.dig('handler', 'qf').keys)
        end
      end

      response '200', 'the object does not match' do
        schema '$ref' => '#/components/schemas/SearchExplanation'
        let(:q) { 'whaling logbook' }

        run_test! do |response|
          expect(response.parsed_body).to include('matched' => false, 'score' => 0.0)
          expect(response.parsed_body.dig('explanation', 'match')).to be(false)
        end
      end

      response '400', 'blank q' do
        let(:q) { ' ' }

        run_test!
      end

      response '404', 'a Set' do
        let(:id) { Compilation.create!(title: 'A Set', depositor: '000000004').noid }
        let(:q)  { 'coastal' }

        run_test!
      end

      response '404', 'a type the catalog search does not return' do
        let(:id) { PersonCreator.call(nuid: '001234567', display_name: 'Doe, Jane').noid }
        let(:q)  { 'doe' }

        run_test!
      end

      response '404', 'the object has no Solr document' do
        let(:q) { 'coastal' }

        before { Atlas.index_adapter.persister.delete(resource: work) }

        run_test! do |response|
          expect(response.parsed_body).to eq('error' => 'not_indexed')
        end
      end
    end
  end
end
