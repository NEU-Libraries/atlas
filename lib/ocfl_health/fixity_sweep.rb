# frozen_string_literal: true

require_relative '../ocfl_health'

module OcflHealth
  # One night's slice of the rolling fixity check, run by bin/ocfl-fixity-sweep.
  # Asks Atlas which objects are due, re-hashes each one read-only, and posts
  # the result to POST /fixity_checks, until the due list, the byte budget or
  # the deadline runs out. Never writes to storage. See docs/fixity.md.
  class FixitySweep
    PAGE = 100
    CHECKER = "ocfl-fixity-sweep #{File.read(File.expand_path('../../.version', __dir__)).strip}".freeze

    Summary = Struct.new(:checked, :failed, :skipped, :bytes, :stopped_by, keyword_init: true)

    # `limits` holds :deadline, a Time; an optional :budget in bytes; and an
    # optional :cycle, the seconds an object rests after a check before it is
    # due again.
    def initialize(pool:, client:, limits:, clock: -> { Time.now.utc }, out: $stdout)
      @pool     = pool
      @client   = client
      @deadline = limits.fetch(:deadline)
      @budget   = limits[:budget]
      @cycle    = limits[:cycle] || 0
      @clock    = clock
      @out      = out
      @summary  = Summary.new(checked: 0, failed: 0, skipped: 0, bytes: 0)
    end

    # The cutoff is a cycle before the run's start, so an object posted during
    # the run drops out of the due list and the next page needs no cursor. An
    # object that could not be posted stays at the front, so it is remembered
    # and passed over.
    def call
      cutoff = @clock.call - @cycle
      passed = Set.new
      loop do
        page = @client.due(before: cutoff, limit: PAGE + passed.size).reject { |entry| passed.include?(entry['key']) }
        return finish(:list) if page.empty?

        page.each do |entry|
          stop = limit_reached
          return finish(stop) if stop

          passed << entry['key'] unless check(entry['key'])
        end
      end
    rescue Client::Refused => e
      log("stopping: #{e.message}")
      finish(:refused)
    end

    private

      def limit_reached
        return :deadline if @clock.call >= @deadline

        :budget if @budget && @summary.bytes >= @budget
      end

      # True when Atlas recorded the result.
      def check(key)
        path = @pool.object_path(key)
        return skip(key, 'no object directory in any root') if path.nil?

        checked_at = @clock.call
        validator  = ObjectValidator.new(path, key: key, fixity: true).call
        return skip(key, 'no readable inventory') if validator.inventory.nil?

        @summary.bytes += validator.bytes_hashed
        record(key, result_body(key, checked_at, validator))
      end

      def record(key, body)
        status, detail = @client.record(body)
        return skip(key, "Atlas answered #{status}: #{detail}") unless [200, 201].include?(status)

        @summary.checked += 1
        @summary.failed += 1 if body[:result] == 'fail'
        log("FAIL #{key}: #{body[:findings].map { |f| f.fetch(:code) }.join(', ')}") if body[:result] == 'fail'
        true
      end

      # A fail is a fatal finding: bytes missing, altered or unreadable. A
      # repairable one is a broken rule with nothing lost, so it rides along on
      # a pass for whoever reads the log.
      def result_body(key, checked_at, validator)
        findings = validator.findings.reject { |f| f.severity == :advisory }
        { object: "#{ObjectValidator::ID_NAMESPACE}:#{key}", checked_at: checked_at.iso8601,
          version: validator.inventory['head'], algorithm: validator.inventory['digestAlgorithm'],
          files: validator.files_hashed, result: findings.any? { |f| f.severity == :fatal } ? 'fail' : 'pass',
          findings: findings.map { |f| { code: f.code.to_s, severity: f.severity.to_s, message: f.message } },
          checker: CHECKER }
      end

      # Nil, so #check reads as not recorded.
      def skip(key, reason)
        @summary.skipped += 1
        log("skipped #{key}: #{reason}")
        nil
      end

      def finish(stopped_by)
        @summary.stopped_by = stopped_by
        s = @summary
        log("done: #{s.checked} checked, #{s.failed} failed, #{s.skipped} skipped, #{s.bytes} bytes; " \
            "stopped by #{stopped_by}")
        s
      end

      def log(message)
        @out.puts("#{@clock.call.iso8601} ocfl-fixity-sweep: #{message}")
      end
  end
end

require_relative 'fixity_sweep/client'
require_relative 'fixity_sweep/cli'
