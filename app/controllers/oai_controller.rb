# frozen_string_literal: true

# The OAI-PMH 2.0 provider at /oai — the endpoint Boston Public Library
# harvests into Digital Commonwealth, replacing Cerberus v1's Blacklight one.
#
# Inherits ActionController::Base, not ApplicationController, for the reasons
# DocsController already documents: the JSON-only :require_auth and
# check_authorization chain must not gate a public protocol endpoint, and
# ActionController::API carries no view layer, so the XML templates would
# render empty. The cop stays off because its autocorrect breaks both.
#
# There is no authenticated principal here, by design. A harvest feed sees the
# literal `public` read group and nothing else — never a caller's groups — so
# the visibility of every response is fixed and cannot be widened by a header.
#
# One action for six verbs: OAI-PMH dispatches on the `verb` argument, not the
# path, and requires one baseURL answering both GET and POST.
class OAIController < ActionController::Base # rubocop:disable Rails/ApplicationController
  CONTENT_TYPE = 'text/xml; charset=utf-8'

  # The protocol's own form encoding. A POST body in any other encoding
  # carries no arguments this endpoint can read.
  FORM_CONTENT_TYPE = 'application/x-www-form-urlencoded'

  # An explicit map rather than a method name derived from the verb: the six
  # handlers stay greppable, and the send target cannot be anything this table
  # does not name.
  HANDLERS = { 'Identify'            => :identify,
               'ListMetadataFormats' => :list_metadata_formats,
               'ListSets'            => :list_sets,
               'ListIdentifiers'     => :list_identifiers,
               'ListRecords'         => :list_records,
               'GetRecord'           => :fetch_record }.freeze

  # Every response is 200, including the error ones. OAI-PMH keeps its own
  # errors distinct from HTTP status codes — the status reports the transport,
  # the <error> element reports the protocol — so a badVerb is a successful
  # HTTP exchange carrying an OAI-PMH error.
  def index
    @oai = OAI::Request.new(raw_args)
    handle_verb if @oai.valid?

    response.content_type = CONTENT_TYPE
    render @oai.valid? ? @oai.verb.underscore : 'error', layout: 'oai', formats: [:xml]
  end

  private

    def handle_verb
      send(HANDLERS.fetch(@oai.verb))
    end

    def identify
      @earliest_datestamp = OAIWorksQuery.earliest_datestamp
    end

    # The format list does not vary by record — every Work carries MODS, and
    # the oai_dc crosswalk reads the JSON copy every Work also carries. An
    # identifier is still resolved when supplied, because a harvester asking
    # about a record that is not here deserves idDoesNotExist rather than a
    # list that does not apply.
    def list_metadata_formats
      return if @oai.identifier.blank?

      record = resolve_record(@oai.identifier, metadata: false)
      return if record.nil?

      # A withdrawn record's metadata is gone in every format; only its header
      # survives, which is exactly what GetRecord returns for it.
      @oai.error!('noMetadataFormats', 'the record is deleted and has no metadata') if record.deleted?
    end

    def list_sets
      # No ListSets response is ever partitioned — the published scope is
      # capped well below any plausible number of sets — so a token here was
      # never issued by this repository.
      return @oai.error!('badResumptionToken', 'ListSets is never partitioned') if @oai.resumed?

      @sets = Compilation.published
      @oai.error!('noSetHierarchy', 'this repository has no published sets') if @sets.empty?
    end

    def list_identifiers
      list_verb(metadata: false)
    end

    def list_records
      list_verb(metadata: true)
    end

    def fetch_record
      @record = resolve_record(@oai.identifier, metadata: true)
    end

    # ListIdentifiers and ListRecords differ only in how much of each record
    # they carry, so they share one path: resolve the set, fetch a page, decide
    # whether a resumptionToken is owed.
    def list_verb(metadata:)
      compilation = resolve_set
      return if @oai.errors.any?

      result = OAIWorksQuery.call(
        compilation: compilation, from: @oai.from, until_time: @oai.until_time,
        cursor_mark: @oai.cursor_mark, rows: page_size(metadata), metadata: metadata
      )
      return @oai.error!('noRecordsMatch', 'no records match the request') if result.docs.empty?

      @records = OAI::Record.build(result.docs, metadata_prefix: metadata ? @oai.metadata_prefix : nil)
      @token   = next_token(result)
    end

    # An unknown or unpublished set denotes no records rather than a malformed
    # request — the argument is well formed, it just names nothing harvestable.
    def resolve_set
      return nil if @oai.set.blank?

      set = Compilation.published.find_by(noid: @oai.set)
      @oai.error!('noRecordsMatch', "no published set #{@oai.set}") if set.nil?
      set
    end

    # Three outcomes:
    #   - more records remain: a token that resumes at the next cursor.
    #   - the list ended and was partitioned: an empty token, which is how a
    #     harvester learns it reached the last part.
    #   - the whole list fitted in one response: no token element at all. It
    #     was never partitioned, so there is no "last part" to announce.
    def next_token(result)
      delivered = @oai.cursor + result.docs.length
      total     = @oai.complete_list_size&.to_i || result.total

      if delivered >= total
        return nil unless @oai.resumed?

        return OAI::Token.new(value: nil, cursor: @oai.cursor, complete_list_size: total)
      end

      OAI::Token.new(
        value:              OAI::ResumptionToken.encode(token_payload(result, total)),
        cursor:             @oai.cursor,
        complete_list_size: total
      )
    end

    def token_payload(result, total)
      { 'metadataPrefix'   => @oai.metadata_prefix,
        'set'              => @oai.set,
        'from'             => @oai.from&.utc&.iso8601,
        'until'            => @oai.until_time&.utc&.iso8601,
        'cursorMark'       => result.cursor_mark,
        'cursor'           => @oai.cursor + result.docs.length,
        'completeListSize' => total }.compact
    end

    def page_size(metadata)
      metadata ? OAI.config.records_per_page : OAI.config.identifiers_per_page
    end

    # Resolves an OAI identifier to a record, recording idDoesNotExist for an
    # identifier this repository never minted and for a Work that is not
    # harvestable — the two are deliberately indistinguishable, so a private
    # Work is not disclosed by the shape of the error. Returns nil in both
    # cases.
    def resolve_record(identifier, metadata:)
      noid = OAI.noid_from(identifier)
      doc  = noid && OAIWorksQuery.find(noid, metadata: metadata)
      return OAI::Record.build([doc], metadata_prefix: metadata ? @oai.metadata_prefix : nil).first if doc

      @oai.error!('idDoesNotExist', "#{identifier} is not a known identifier in this repository")
      nil
    end

    # OAI-PMH treats a repeated argument as an error, so the raw multimap is
    # what validation needs — Rails' params has already collapsed a duplicate
    # to its last value. Rack::Utils.parse_query keeps both.
    def raw_args
      merged = Hash.new { |hash, key| hash[key] = [] }
      [request.query_string, form_body].each do |source|
        Rack::Utils.parse_query(source.to_s).each { |key, value| merged[key].concat(Array(value)) }
      end
      merged
    end

    def form_body
      request.post? && request.media_type == FORM_CONTENT_TYPE ? request.raw_post : ''
    end
end
