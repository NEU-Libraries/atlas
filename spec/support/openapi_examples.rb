# frozen_string_literal: true

# Recorded response bodies, attached to the OpenAPI documents as examples.
# The generator runs with --dry-run, so an example cannot come from a response
# at generation time: a request-spec run with RECORD_EXAMPLES=1 writes them to
# spec/openapi_examples instead, scrubbed, and OpenapiContract.finish reads
# them. Every example is published, so it holds nothing that is not safe to
# publish. docs/openapi.md explains the cycle.
module OpenapiExamples
  DIR = Rails.root.join('spec/openapi_examples')

  # The placeholders the scrubber writes, which the safety spec allows.
  NOID_PLACEHOLDER  = /\Ad\d{7}x\z/
  UUID_PLACEHOLDER  = /\A00000000-0000-4000-8000-\d{12}\z/
  EMAIL_PLACEHOLDER = /\Aperson\d+@example\.org\z/
  TIMESTAMP         = '2026-01-15T12:00:00Z'
  DATE              = '2026-01-15'
  SECRET            = '<redacted>'
  SECRET_KEYS       = %w[jti token password encrypted_password reset_password_token].freeze

  # Numbers that change from run to run: a database row id, and Solr's
  # optimistic-lock version.
  VOLATILE_NUMBERS = { 'id' => 1, '_version_' => 0 }.freeze

  # The shape of a NOID that holds a letter, for the safety spec. An all-digit
  # NOID looks like a NUID, so the scrubber matches the NOIDs the database
  # holds instead of guessing from the shape.
  NOID      = /(?<![0-9a-z])(?=[0-9a-z]*\d)(?=[0-9a-z]*[a-z])[0-9bcdfghjkmnpqrstvwxz]{9}(?![0-9a-z])/
  UUID      = /\b\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\b/
  EMAIL     = /\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b/
  DATETIME  = /\A\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2}| UTC)?\z/
  DATE_ONLY = /\A\d{4}-\d{2}-\d{2}\z/
  DATE_IN   = /(?<!\d)\d{4}-\d{2}-\d{2}(?!\d)/
  DIGEST    = /\A((?:sha256|sha512|md5|sha1):)?(\h{32,128})\z/

  # Hosts a published example may name: the reserved example domains, which
  # specs use for every outside service, and the global Handle proxy.
  RESERVED_HOSTS = /(\A|\.)(example(\.org|\.com|\.net)?|invalid)\z/

  # Public hosts the fixtures name on purpose. Every new one is a decision
  # that its URLs are safe to publish, so the list is explicit.
  PUBLIC_HOSTS = %w[
    hdl.handle.net
    www.loc.gov id.loc.gov www.w3.org purl.org rs.tdwg.org creativecommons.org
    repository.neu.edu
    arctos.database.museum
  ].freeze

  # NOID-shaped strings that are not NOIDs: the handle suffix in
  # spec/fixtures/files/work-mods.xml, as Solr's analysis lowercases it.
  PUBLIC_TOKENS = %w[d20254217].freeze

  module_function

  def recording?
    ENV['RECORD_EXAMPLES'].present?
  end

  # repository.neu.edu appears only as a MODS namespace URI, and
  # arctos.database.museum as the occurrenceID of a public specimen record in
  # the Darwin Core fixtures. The rest are standards and licence URLs.
  def publishable_host?(host)
    host.match?(RESERVED_HOSTS) || PUBLIC_HOSTS.include?(host)
  end

  # One file per operation and status, keyed on the verb and path rather than
  # the operationId, which is only settled once the whole document is built.
  def path_for(template, verb, code)
    DIR.join(OpenapiContract.path_operation_id(template, verb), "#{code}.json")
  end

  def record(metadata, response, example_id)
    code = metadata.dig(:response, :code).to_s
    return unless code.start_with?('2') && response.media_type == 'application/json' && response.body.present?

    file = path_for(metadata.dig(:path_item, :template), metadata.dig(:operation, :verb).to_s, code)
    return if recorded.key?(file) && recorded[file] <= example_id

    recorded[file] = example_id
    FileUtils.mkdir_p(file.dirname)
    File.write(file, "#{JSON.pretty_generate(scrub(JSON.parse(response.body), known_noids))}\n")
  end

  # Every NOID this example's world holds, read while its fixtures still exist.
  def known_noids
    Atlas.query.find_all.flat_map { |resource| Array(resource.alternate_ids).map(&:to_s) } +
      Compilation.pluck(:noid) + PurgedIdentifier.pluck(PurgedIdentifier.primary_key)
  end

  # The example each file holds in this run. The lowest RSpec id wins, so two
  # recordings of unchanged code pick the same response.
  def recorded
    @recorded ||= {}
  end

  # A route that serves XML and JSON documents no schema, because rswag would
  # give both media types the same one; its recorded JSON body still gets a
  # JSON media type to sit under.
  def attach(doc)
    OpenapiContract.operations(doc).each do |template, verb, op|
      op['responses'].each { |code, response| attach_to(response, path_for(template, verb, code)) }
    end
  end

  def attach_to(response, file)
    return unless response.is_a?(Hash) && !response.key?('$ref') && file.exist?

    media = ((response['content'] ||= {})['application/json'] ||= {})
    media['example'] ||= JSON.parse(file.read)
  end

  # Replaces everything that changes from run to run, or must not be
  # published, with a stable placeholder. The same value in one body maps to
  # the same placeholder, so a reader can still follow an id from field to field.
  def scrub(body, noids)
    Scrubber.new(noids).call(body)
  end

  # The state of one scrub: the placeholders handed out so far.
  class Scrubber
    def initialize(known)
      known   = known.compact_blank.uniq.sort_by { |noid| -noid.length }
      @known  = known.empty? ? nil : /(?<![0-9a-z])(?:#{known.map { Regexp.escape(it) }.join('|')})(?![0-9a-z])/
      @noids  = {}
      @uuids  = {}
      @emails = {}
    end

    def call(node, key = nil)
      case node
      when Hash   then node.to_h { |k, v| [k, call(v, k)] }
      when Array  then node.map { |v| call(v, key) }
      when String then string(node, key)
      when Integer then VOLATILE_NUMBERS.fetch(key.to_s, node)
      else node
      end
    end

    private

      def string(value, key)
        return SECRET if SECRET_KEYS.include?(key.to_s)
        return TIMESTAMP if value.match?(DATETIME)
        return DATE if value.match?(DATE_ONLY)
        return digest(value) if value.match?(DIGEST)

        value.gsub(UUID) { |uuid| placeholder(@uuids, uuid) { |n| format('00000000-0000-4000-8000-%012d', n) } }
             .gsub(EMAIL) { |email| placeholder(@emails, email) { |n| "person#{n}@example.org" } }
             .then { |text| @known ? text.gsub(@known) { |noid| placeholder(@noids, noid) { |n| format('d%07dx', n) } } : text }
             .gsub(DATE_IN, DATE)
      end

      def digest(value)
        prefix, hex = value.match(DIGEST).captures
        "#{prefix}#{('0123456789abcdef' * 8)[0, hex.length]}"
      end

      def placeholder(seen, value)
        seen[value] ||= yield(seen.size + 1)
      end
  end
end
