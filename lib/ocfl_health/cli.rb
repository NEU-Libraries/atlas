# frozen_string_literal: true

require 'optparse'

module OcflHealth
  # bin/ocfl-health. Exit status is the worst grade, so a script can branch on
  # it: 0 green, 1 yellow, 2 red, 64 for a usage error.
  class CLI
    EXIT = { green: 0, yellow: 1, red: 2 }.freeze
    USAGE_ERROR = 64

    def self.run(argv, out: $stdout)
      new(out).run(argv)
    end

    def initialize(out)
      @out = out
      @roots = []
      @fixity = true
      @json = false
      @verbose = false
    end

    def run(argv)
      noids = parse(argv)
      return USAGE_ERROR if noids.nil?

      pool = Pool.new(@roots)
      results = noids.empty? ? sweep(pool) : noids.map { |noid| WorkAssessment.new(pool, noid, fixity: @fixity).call }
      grades = results.map(&:grade) + [OcflHealth.grade(pool.findings)]
      emit(pool, results)
      EXIT.fetch(worst(grades))
    end

    private

      def parse(argv)
        options.parse!(argv)
        @roots = ENV.fetch('OCFL_ROOTS', '').split(':') if @roots.empty?
        return argv unless @roots.empty?

        warn 'give at least one --root, or set OCFL_ROOTS'
        warn options
        nil
      rescue OptionParser::ParseError => e
        warn e.message
        nil
      end

      def options
        @options ||= OptionParser.new do |o|
          o.banner = "Usage: bin/ocfl-health --root PATH [--root PATH ...] [options] [WORK_NOID ...]\n\n" \
                     "With NOIDs, assesses each as a Work: its graph on disk and every object it reaches.\n" \
                     "Without, validates every object in the pool.\n\n"
          o.on('--root PATH', 'An OCFL storage root; repeat for a pool') { |path| @roots << path }
          o.on('--no-fixity', 'Skip re-hashing content (structure only)') { @fixity = false }
          o.on('--json', 'One JSON document on stdout') { @json = true }
          o.on('-v', '--verbose', 'List advisory findings too') { @verbose = true }
        end
      end

      Sweep = Struct.new(:key, :findings) do
        def grade = OcflHealth.grade(findings)
        def to_h = { noid: key, grade: grade, findings: findings.map(&:to_h) }
      end

      def sweep(pool)
        pool.each_object.map do |key, path, _root|
          validator = ObjectValidator.new(path, key: key, fixity: @fixity).call
          Sweep.new(key, validator.findings + Envelope.read(validator).findings)
        end
      end

      def worst(grades)
        %i[red yellow green].find { |g| grades.include?(g) } || :green
      end

      def emit(pool, results)
        return @out.puts(JSON.pretty_generate(pool: pool.findings.map(&:to_h), results: results.map(&:to_h))) if @json

        pool.findings.each { |f| line(f) }
        results.each { |result| emit_result(result) }
        summary(results)
      end

      # A sweep lists only the objects that need attention; a Work is always shown.
      def emit_result(result)
        shown = @verbose ? result.findings : result.findings.reject { |f| f.severity == :advisory }
        return if result.is_a?(Sweep) && shown.empty? && result.grade == :green

        header(result)
        shown.each { |f| line(f) }
      end

      def header(result)
        if result.is_a?(WorkAssessment)
          @out.puts "Work #{result.noid}  #{result.grade.upcase}"
          @out.puts "  #{facts_line(result.facts)}"
        else
          @out.puts "Object #{result.key}  #{result.grade.upcase}"
        end
      end

      def facts_line(facts)
        facts.compact.map { |k, v| "#{k}=#{v.is_a?(Array) ? v.join('>') : v}" }.join('  ')
      end

      def line(finding)
        @out.puts format('    %<sev>-10s %<code>-32s %<subject>-9s %<msg>s',
                         sev: finding.severity, code: finding.code, subject: finding.subject, msg: finding.message)
      end

      def summary(results)
        counts = results.map(&:grade).tally
        @out.puts "#{results.size} checked: " + %i[green yellow red].map { |g| "#{counts.fetch(g, 0)} #{g}" }.join(', ')
      end
  end
end
