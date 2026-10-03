# frozen_string_literal: true

# GET /resources/:id/solr: one object's Solr document, exactly as Solr stores
# it. See docs/solr-indexing.md.
class IndexDocumentQuery
  include SolrRefs

  def self.call(noid)
    new.call(noid)
  end

  # fl=* because the handler's default fl adds a score, which means nothing on
  # a *:* query.
  def call(noid)
    connection.get('select', params: { q: '*:*', fq: noid_filter(noid), rows: 1, fl: '*', facet: false })
              .dig('response', 'docs', 0)
  end
end
