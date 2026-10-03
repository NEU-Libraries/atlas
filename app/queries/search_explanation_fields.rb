# frozen_string_literal: true

# The per-field half of the search explanation: each searched field's stored
# text, analysed against the query, with the tokens that matched. See
# docs/search.md.
class SearchExplanationFields
  def initialize(plans:, document:, highlights:, analysis:)
    @plans      = plans
    @document   = document
    @highlights = highlights
    @analysis   = analysis
  end

  # The last request analyses the query alone, so a field with no stored text
  # still shows how the query reads in it.
  def call
    values    = capped_values
    requests  = values.map { |value| { fields: feeds(value[:source]), value: value[:text] } }
    responses = @analysis.run(requests + [{ fields: @plans.select { |plan| plan[:known] }.pluck(:field), value: nil }])
    query_side = responses.pop
    analysed   = values.zip(responses)
    @plans.map { |plan| report(plan, analysed, query_side) }
  end

  private

    # Capped per source, so a record with hundreds of subjects cannot fan out
    # into hundreds of requests.
    def capped_values
      @plans.flat_map { |plan| plan[:sources] }.uniq.flat_map do |source|
        Array(@document[source]).first(SearchExplanationQuery::VALUE_CAP)
                                .map { |text| { source: source, text: text.to_s } }
      end
    end

    # Every searched field a source feeds, so one request analyses its value
    # for all of them.
    def feeds(source)
      @plans.select { |plan| plan[:sources].include?(source) }.pluck(:field)
    end

    def report(plan, analysed, query_side)
      field = plan[:field]
      mine  = analysed.select { |value, _response| plan[:sources].include?(value[:source]) }
      { field: field, stored: plan[:stored],
        query_tokens: SolrFieldAnalysis.query_tokens(query_side&.dig(field, 'query')),
        values: tokenised(field, mine), truncated: truncated?(plan),
        reason: reason(plan, mine.any? { |_value, response| response.nil? }),
        highlights: field == SearchExplanationQuery::FULL_TEXT_FIELD ? @highlights : [] }
    end

    # A value whose analysis failed is left out; `reason` says so.
    def tokenised(field, analysed)
      analysed.filter_map do |value, response|
        response && value.merge(tokens: SolrFieldAnalysis.index_tokens(response.dig(field, 'index')))
      end
    end

    def truncated?(plan)
      plan[:sources].any? { |source| Array(@document[source]).size > SearchExplanationQuery::VALUE_CAP }
    end

    def reason(plan, failed)
      return 'not_in_schema' unless plan[:known]
      return 'full_text' if plan[:field] == SearchExplanationQuery::FULL_TEXT_FIELD
      return 'not_stored' if plan[:sources].empty?

      'analysis_failed' if failed
    end
end
