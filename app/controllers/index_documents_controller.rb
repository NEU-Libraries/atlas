# frozen_string_literal: true

# An object's raw Solr document, for debugging the index from an API client.
# Admins and delegated admins only. See docs/solr-indexing.md.
class IndexDocumentsController < ApplicationController
  include IndexReadGate

  def show
    resource = Resource.find(params.expect(:id))
    authorize_index_read!(resource)
    return head(:not_found) if resource.nil?

    @noid     = resource.noid
    @document = IndexDocumentQuery.call(@noid)
    render_error(:not_found, 'not_indexed') if @document.nil?
  end
end
