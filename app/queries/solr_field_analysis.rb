# frozen_string_literal: true

# Solr's field analysis for the search explanation: one request per stored
# value, sent several at a time, each reduced to the token lists a client
# reads. See docs/search.md.
class SolrFieldAnalysis
  THREADS = 8

  def initialize(connection, query)
    @connection = connection
    @query      = query
  end

  # Each request is { fields:, value: }, and a nil value analyses the query
  # side alone. Answers one entry per request, in order: Solr's field_names
  # hash, or nil when that request failed.
  def run(requests)
    pool    = Concurrent::FixedThreadPool.new(THREADS)
    futures = requests.map { |request| Concurrent::Promises.future_on(pool) { analyse(request) } }
    futures.map(&:value)
  ensure
    pool&.shutdown
  end

  # Solr leaves `match` out when a token does not match; the client gets false.
  def self.index_tokens(stages)
    token_stages(stages).last.to_a.map do |token|
      { text: token['text'], start: token['start'], end: token['end'], position: token['position'],
        match: token['match'] == true }
    end
  end

  # The first stage is the words as typed, the last as Solr searches them, so
  # a client can map `survey` back to `surveys`.
  def self.query_tokens(stages)
    lists = token_stages(stages)
    return nil if lists.empty?

    { typed: lists.first.pluck('text'), analysed: lists.last.pluck('text') }
  end

  # Stages alternate a class name and its output. A char filter's output is a
  # string rather than tokens, so only the arrays are token stages.
  def self.token_stages(stages)
    Array(stages).each_slice(2).map(&:last).grep(Array)
  end

  private

    # POST, because a long description would overflow a request line.
    def analyse(request)
      data = { 'analysis.fieldname' => request[:fields].join(','), 'analysis.query' => @query,
               'analysis.showmatch' => true }
      data['analysis.fieldvalue'] = request[:value] if request[:value]
      @connection.post('analysis/field', data: data).dig('analysis', 'field_names')
    end
end
