# frozen_string_literal: true

module OAI
  # Argument validation for every /oai request, in one place.
  #
  # Conformance is usually lost here rather than in the response bodies, and
  # the rules interact: a resumptionToken excludes the other arguments, but
  # supplies them, and the arguments it supplies must not be re-validated
  # against what the harvester sent this time. Keeping all of it in one object
  # means OAIController never asks "is this argument allowed" — it asks the
  # request what it resolved to.
  #
  # Errors accumulate rather than short-circuit: OAI-PMH allows several
  # <error> elements in one response, and a harvester debugging a query is
  # better served by all of them.
  class Request
    Error = Struct.new(:code, :message)

    VERBS = %w[Identify ListMetadataFormats ListSets
               ListIdentifiers ListRecords GetRecord].freeze

    # Arguments each verb accepts, beyond `verb` itself.
    ALLOWED = {
      'Identify'            => [],
      'ListMetadataFormats' => %w[identifier],
      'ListSets'            => %w[resumptionToken],
      'ListIdentifiers'     => %w[from until set metadataPrefix resumptionToken],
      'ListRecords'         => %w[from until set metadataPrefix resumptionToken],
      'GetRecord'           => %w[identifier metadataPrefix]
    }.freeze

    REQUIRED = {
      'ListIdentifiers' => %w[metadataPrefix],
      'ListRecords'     => %w[metadataPrefix],
      'GetRecord'       => %w[identifier metadataPrefix]
    }.freeze

    attr_reader :errors, :verb, :metadata_prefix, :identifier, :set,
                :from, :until_time, :cursor_mark, :cursor, :complete_list_size

    # `args` is a multimap — { 'verb' => ['ListRecords'], … } — because a
    # repeated argument is a badArgument and a plain params hash has already
    # thrown the duplicate away.
    def initialize(args)
      @args        = args
      @errors      = []
      @cursor_mark = '*'
      @cursor      = 0
      validate
    end

    def valid?
      errors.empty?
    end

    def resumed?
      @resumed
    end

    # OAI-PMH: on badVerb and badArgument the <request> element carries no
    # attributes at all, because the repository could not make sense of them.
    # Every other response echoes exactly what the harvester sent.
    def echo_attributes
      return {} if errors.any? { |e| %w[badVerb badArgument].include?(e.code) }

      @args.filter_map { |key, values| [key, values.first] if values.length == 1 }.to_h
    end

    def error!(code, message)
      errors << Error.new(code, message)
    end

    private

      def validate
        return unless validate_verb

        reject_repeated_arguments
        reject_blank_arguments
        reject_unknown_arguments
        apply_resumption_token
        require_arguments
        validate_dates
        validate_metadata_prefix
      end

      def validate_verb
        verbs = Array(@args['verb'])
        if verbs.empty?
          error!('badVerb', 'the verb argument is missing')
        elsif verbs.length > 1
          error!('badVerb', 'the verb argument is repeated')
        elsif VERBS.exclude?(verbs.first)
          error!('badVerb', "#{verbs.first} is not a legal OAI-PMH verb")
        else
          @verb = verbs.first
        end
        @verb.present?
      end

      def reject_repeated_arguments
        @args.each do |key, values|
          error!('badArgument', "the #{key} argument is repeated") if values.length > 1
        end
      end

      def reject_blank_arguments
        @args.each do |key, values|
          next if key == 'verb'

          error!('badArgument', "the #{key} argument has no value") if values.all?(&:blank?)
        end
      end

      def reject_unknown_arguments
        (@args.keys - ['verb'] - ALLOWED.fetch(@verb)).each do |key|
          error!('badArgument', "#{key} is not a legal argument for #{@verb}")
        end
      end

      # A resumptionToken is exclusive: OAI-PMH forbids sending it alongside
      # any other argument, because the token already fixes them. Decoding it
      # replaces from / until / set / metadataPrefix wholesale, which is what
      # stops a harvester changing them halfway through a list.
      def apply_resumption_token
        token = single('resumptionToken')
        return if token.blank?

        others = @args.keys - %w[verb resumptionToken]
        return error!('badArgument', 'resumptionToken cannot be combined with other arguments') if others.any?

        payload = ResumptionToken.decode(token)
        @resumed            = true
        @metadata_prefix    = payload['metadataPrefix']
        @set                = payload['set']
        @from               = payload['from'].presence && Time.parse(payload['from']).utc
        @until_time         = payload['until'].presence && Time.parse(payload['until']).utc
        @cursor_mark        = payload['cursorMark'].presence || '*'
        @cursor             = payload['cursor'].to_i
        @complete_list_size = payload['completeListSize']
      rescue ResumptionToken::InvalidToken
        error!('badResumptionToken', 'the resumptionToken is invalid or was not issued by this repository')
      end

      def require_arguments
        return if resumed? || errors.any?

        @identifier      = single('identifier')
        @metadata_prefix = single('metadataPrefix')
        @set             = single('set')

        REQUIRED.fetch(@verb, []).each do |key|
          error!('badArgument', "the #{key} argument is required for #{@verb}") if single(key).blank?
        end
      end

      # The rules live in OAI::DateRange; anything it rejects is badArgument.
      def validate_dates
        return if resumed? || errors.any?

        range = DateRange.new(from: single('from'), until_time: single('until'))
        range.errors.each { |message| error!('badArgument', message) }
        @from       = range.from
        @until_time = range.until_time
      end

      # cannotDisseminateFormat, not badArgument: the argument is well formed,
      # the repository simply does not speak that format.
      def validate_metadata_prefix
        return if errors.any? || @metadata_prefix.blank?
        return if FORMATS.key?(@metadata_prefix)

        error!('cannotDisseminateFormat', "#{@metadata_prefix} is not supported by this repository")
      end

      def single(key)
        values = Array(@args[key])
        values.length == 1 ? values.first.presence : nil
      end
  end
end
