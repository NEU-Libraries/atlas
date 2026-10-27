# frozen_string_literal: true

# One fixity check result as posted to POST /fixity_checks, checked and put in
# the canonical form a log line takes. Raises Exceptions::FixityCheckError, so
# a bad body writes nothing. See docs/fixity.md.
class FixityCheck
  OBJECT = /\A#{Regexp.escape(Valkyrie::Storage::OCFL::INVENTORY_ID_NAMESPACE)}:(?<key>[A-Za-z0-9]+)\z/
  VERSION = /\Av[1-9]\d*\z/

  # The digest algorithms OCFL 1.1 names, for the inventory and its fixity block.
  ALGORITHMS = %w[sha512 sha256 sha1 md5 blake2b-512 blake2b-160 blake2b-256 blake2b-384 sha512/256].freeze

  FINDING_KEYS = %w[code severity subject message path].freeze
  MAX_FINDINGS = 1000
  MAX_TEXT = 1000
  MAX_CHECKER = 64

  # A checker's clock may run a little ahead of Atlas's; a result much further
  # ahead would sit as the latest check and hide every real one after it.
  CLOCK_SKEW = 5.minutes

  attr_reader :key, :checked_at, :version, :result, :checker

  def initialize(body, recorded_by:)
    @body        = body
    @recorded_by = recorded_by
    parse!
  end

  # Keys in a fixed order, so a retried post produces the identical line and
  # the log records it once.
  def to_h
    { object: @object, checked_at: checked_at.iso8601, version: version, algorithm: @algorithm,
      files: @files, result: result, findings: @findings, checker: checker,
      recorded_by: @recorded_by }
  end

  def to_log_line
    to_h.to_json
  end

  private

    def parse!
      @object     = parse_object
      @checked_at = parse_checked_at
      @version    = matching(:version, VERSION, 'a version name such as v3')
      @algorithm  = parse_algorithm
      @files      = parse_files
      @result     = parse_result
      @findings   = parse_findings
      @checker    = parse_checker
    end

    def parse_object
      match = OBJECT.match(@body['object'].to_s)
      reject(:invalid_object, "object must be #{Valkyrie::Storage::OCFL::INVENTORY_ID_NAMESPACE}:<noid>") unless match
      @key = match[:key]
      match[0]
    end

    def parse_checked_at
      # Whole seconds, the precision the log line carries, so the row and the
      # line it caches never disagree.
      time = Time.iso8601(@body['checked_at'].to_s).utc.change(usec: 0)
      reject(:invalid_checked_at, 'checked_at is in the future') if time > Time.current + CLOCK_SKEW
      time
    rescue ArgumentError
      reject(:invalid_checked_at, 'checked_at must be an ISO 8601 timestamp')
    end

    def parse_algorithm
      value = @body['algorithm'].to_s
      return value if ALGORITHMS.include?(value)

      reject(:invalid_algorithm, "algorithm must be one of #{ALGORITHMS.join(', ')}")
    end

    def parse_files
      value = @body['files']
      return value if value.is_a?(Integer) && !value.negative?

      reject(:invalid_files, 'files must be a non-negative integer')
    end

    def parse_result
      value = @body['result'].to_s
      return value if FixityResult::RESULTS.include?(value)

      reject(:invalid_result, "result must be one of #{FixityResult::RESULTS.join(', ')}")
    end

    # A fail must say what failed: a bare "fail" in the log tells a reader
    # nothing they could act on.
    def parse_findings
      raw = @body['findings'] || []
      unless findings?(raw)
        reject(:invalid_findings, "findings must be up to #{MAX_FINDINGS} objects, each with a code")
      end
      reject(:invalid_findings, 'a fail must carry at least one finding') if raw.empty? && @body['result'] == 'fail'

      raw.map { |finding| finding_hash(finding).slice(*FINDING_KEYS).compact }
    end

    def findings?(raw)
      raw.is_a?(Array) && raw.size <= MAX_FINDINGS && raw.all? { |finding| finding?(finding) }
    end

    def finding?(finding)
      hash = finding_hash(finding)
      return false unless hash.is_a?(Hash) && hash['code'].is_a?(String) && hash['code'].present?

      hash.slice(*FINDING_KEYS).values.all? { |value| value.nil? || (value.is_a?(String) && value.length <= MAX_TEXT) }
    end

    def finding_hash(finding)
      finding.respond_to?(:to_unsafe_h) ? finding.to_unsafe_h : finding
    end

    def parse_checker
      value = @body['checker']
      return value if value.is_a?(String) && value.present? && value.length <= MAX_CHECKER

      reject(:invalid_checker, "checker must name the tool that ran the check, at most #{MAX_CHECKER} characters")
    end

    def matching(field, pattern, description)
      value = @body[field.to_s].to_s
      return value if pattern.match?(value)

      reject(:"invalid_#{field}", "#{field} must be #{description}")
    end

    def reject(code, message)
      raise Exceptions::FixityCheckError.new(code, message)
    end
end
