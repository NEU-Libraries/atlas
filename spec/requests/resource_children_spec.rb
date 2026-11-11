# frozen_string_literal: true

require 'swagger_helper'

# The response shape, which drives the OpenAPI entry. Who may call it is
# index_read_gate_spec.rb.
RSpec.describe 'Resource children', type: :request do
  let(:community)  { public_community! }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:nested)     { CollectionCreator.call(parent_id: collection.noid) }

  after { Atlas.persister.wipe! }

  def tombstone!(resource)
    resource = Resource.find(resource.noid)
    resource.tombstone(by: '000000004')
    Atlas.persister.save(resource: resource)
  end

  path '/resources/{id}/children' do
    get "A container's children, tombstoned ones included" do
      tags 'Resources'
      response_texts(
        '200' => 'The container\'s direct children, live and tombstoned, each flagged with `tombstoned`.',
        '404' => 'No Community or Collection has that NOID.'
      )
      produces 'application/json'
      description <<~DESC
        Every Community, Collection and Work directly beneath a Community or
        Collection, live or tombstoned, for inspecting the graph. Unlike
        `/collections/{id}/children` and `/communities/{id}/children`, it
        answers for a tombstoned container instead of 410. Each row has the
        `POST /resources/find_many` digest shape, `tombstoned` included.

        Admins and delegated admins only, the gate of
        `GET /resources/{id}/solr`. A delegated admin must also be able to read
        the container, and a child they cannot read is left out. Not
        response-cached.

        404 for an unknown NOID and for anything other than a Community or a
        Collection.

        Only an admin or a delegated admin may call this; anyone else gets
        `403`.
      DESC
      parameter name: :id, in: :path, type: :string, description: 'NOID of the Community or Collection'

      response '200', 'the children of a tombstoned container' do
        schema '$ref' => '#/components/schemas/ResourceDigests'
        let(:id) { collection.noid }

        before do
          tombstone!(work)
          tombstone!(nested)
          tombstone!(collection)
        end

        run_test! do |response|
          rows = response.parsed_body.index_by { |row| row['id'] }
          expect(rows.keys).to contain_exactly(work.noid, nested.noid)
          expect(rows.dig(work.noid, 'klass')).to eq('Work')
          expect(rows.dig(nested.noid, 'klass')).to eq('Collection')
          expect(rows.values.pluck('tombstoned')).to all(be(true))
        end
      end

      response '200', 'a live container lists live and tombstoned children alike' do
        schema '$ref' => '#/components/schemas/ResourceDigests'
        let(:id) { collection.noid }

        before do
          nested
          tombstone!(work)
        end

        run_test! do |response|
          flags = response.parsed_body.to_h { |row| [row['id'], row['tombstoned']] }
          expect(flags).to eq(work.noid => true, nested.noid => false)
        end
      end

      response '404', 'unknown NOID' do
        let(:id) { 'nosuchnoid' }

        run_test!
      end

      response '404', 'a Work, which is not a container' do
        let(:id) { work.noid }

        run_test!
      end
    end
  end

  # The typed route keeps its answer for consumers; only this one opens.
  it 'leaves /collections/:id/children answering 410 for a tombstoned collection' do
    tombstone!(work)
    tombstone!(collection)

    get "/collections/#{collection.noid}/children"

    expect(response).to have_http_status(:gone)
  end
end
