# frozen_string_literal: true

# GET /resources/:id/search_explanation: Solr's own account of how the catalog
# search scores one object for some words, whether it matches or not. Atlas
# chooses the Solr requests and groups what they return; the client interprets
# it. See docs/search.md.
class SearchExplanationQuery
  include SolrRefs

  TYPES           = %w[Work Collection Community].freeze
  VALUE_CAP       = 25
  FULL_TEXT_FIELD = 'full_text_tesimv'

  class NotIndexed < StandardError; end

  def self.call(noid:, query:)
    new(noid: noid, query: query).call
  end

  def initialize(noid:, query:)
    @noid   = noid
    @query  = query
    @schema = SolrSchema.current
  end

  def call
    explained   = explain
    explanation = explained.dig('debug', 'explainOther')&.values&.first
    raise NotIndexed if explanation.nil?

    handler = handler_params(explained.dig('responseHeader', 'params'))
    plans   = handler[:qf].keys.map { |field| plan(field) }
    view    = catalog_view(plans)
    raise NotIndexed if view.dig('response', 'docs', 0).nil?

    summary(explained, explanation, handler, view)
      .merge(fields: fields(plans, view.dig('response', 'docs', 0), explained))
  end

  private

    def summary(explained, explanation, handler, view)
      { noid: @noid, q: @query, matched: explanation['match'] == true, score: explanation['value'],
        hidden_by: hidden_by(view), parsed_query: explained.dig('debug', 'parsedquery_toString'),
        handler: handler, explanation: explanation }
    end

    # explainOther explains the object whether it matches or not; a search
    # narrowed to it would return nothing to explain when it does not. No qf,
    # pf or mm, so the handler's defaults make the ranking the catalog's. No
    # read gate either: the caller has already been authorized on the object.
    def explain
      connection.get('select', params: {
                       q: @query, fq: noid_filter(@noid), rows: 1, fl: 'id,score', facet: false,
                       echoParams: 'all', debug: %w[query results], explainOther: noid_filter(@noid),
                       'debug.explain.structured' => true,
                       hl: true, 'hl.method' => 'unified', 'hl.fl' => FULL_TEXT_FIELD, 'hl.snippets' => 3
                     })
    end

    # q=*:* because facet counts cover only what matches q. A count of 0 means
    # that catalog filter hides the object.
    def catalog_view(plans)
      sources = plans.flat_map { |plan| plan[:sources] }.uniq
      connection.get('select', params: {
                       q: '*:*', fq: noid_filter(@noid), rows: 1, fl: ['id', *sources].join(','), facet: true,
                       'facet.query' => SearchQuery::CATALOG_FILTERS.map { |key, filter| "{!key=#{key}}#{filter}" }
                     })
    end

    def hidden_by(view)
      view.dig('facet_counts', 'facet_queries').to_h.select { |_key, count| count.to_i.zero? }.keys
    end

    def handler_params(params)
      { qf: boosts(params['qf']), pf: boosts(params['pf']), mm: params['mm'],
        tie: params['tie']&.to_f, boost: Array(params['boost']).join(' ').presence }
    end

    # `title_tsim^10 identifier_tesim` becomes { title_tsim: 10.0, identifier_tesim: 1.0 }.
    def boosts(spec)
      Array(spec).join(' ').split.to_h do |entry|
        field, boost = entry.split('^', 2)
        [field, (boost || 1).to_f]
      end
    end

    # A searched field takes its text from itself when stored, and from every
    # field that copies into it. Full text is too long to analyse, so the
    # highlight stands in for it.
    def plan(field)
      known  = @schema.known?(field)
      stored = known && @schema.stored?(field)
      sources = known && field != FULL_TEXT_FIELD ? [*(field if stored), *@schema.copy_sources(field)] : []
      { field: field, known: known, stored: stored, sources: sources }
    end

    def fields(plans, document, explained)
      highlights = Array(explained.fetch('highlighting', {}).values.first.to_h[FULL_TEXT_FIELD])
      SearchExplanationFields.new(plans: plans, document: document, highlights: highlights,
                                  analysis: SolrFieldAnalysis.new(connection, @query)).call
    end
end
