# frozen_string_literal: true

require 'optparse'

module OcflHealth
  class FixitySweep
    # bin/ocfl-fixity-sweep. Exit 0 when the run ends normally, whatever it
    # found: a failed check is recorded in Atlas, not signalled here. Exit 1
    # when Atlas refused or was unreachable, 64 for a usage error.
    class CLI
      USAGE_ERROR = 64
      UNITS = { '' => 1, 'B' => 1, 'KB' => 10**3, 'MB' => 10**6, 'GB' => 10**9, 'TB' => 10**12 }.freeze
      SECONDS = { '' => 1, 's' => 1, 'h' => 3600, 'd' => 86_400 }.freeze
      DEFAULT_CYCLE = '90d'

      def self.run(argv, env: ENV, out: $stdout, clock: -> { Time.now.utc })
        new(env, out, clock).run(argv)
      end

      def initialize(env, out, clock)
        @env   = env
        @out   = out
        @clock = clock
        @roots = []
        @cycle = self.class.seconds(DEFAULT_CYCLE)
      end

      def run(argv)
        options.parse!(argv)
        problem = missing_setting
        return usage(problem) if problem

        summary = FixitySweep.new(pool: Pool.new(roots), client: client, clock: @clock, out: @out,
                                  limits: { deadline: @deadline, budget: @budget, cycle: @cycle }).call
        summary.stopped_by == :refused ? 1 : 0
      rescue OptionParser::ParseError, ArgumentError => e
        usage(e.message)
      end

      # HH:MM is the next time the UTC clock reads it, so a run started at
      # 01:00 with --until 07:00 stops the same morning.
      def self.deadline(value, now)
        return Time.iso8601(value).utc unless value.match?(/\A\d{1,2}:\d{2}\z/)

        hour, minute = value.split(':').map(&:to_i)
        raise ArgumentError, "not a time of day: #{value}" if hour > 23 || minute > 59

        today = Time.utc(now.year, now.month, now.day, hour, minute)
        today > now ? today : today + 86_400
      end

      def self.bytes(value)
        match = value.to_s.strip.match(/\A(\d+(?:\.\d+)?)\s*([KMGT]?B)?\z/i)
        raise ArgumentError, "not a byte size: #{value}" unless match

        (match[1].to_f * UNITS.fetch(match[2].to_s.upcase)).to_i
      end

      # Days, hours or seconds, such as 90d. No minutes or months, because a
      # bare "m" could mean either.
      def self.seconds(value)
        match = value.to_s.strip.match(/\A(\d+)\s*([dhs]?)\z/i)
        raise ArgumentError, "not a duration: #{value}" unless match

        match[1].to_i * SECONDS.fetch(match[2].downcase)
      end

      private

        def options
          OptionParser.new do |o|
            o.banner = 'Usage: bin/ocfl-fixity-sweep --until HH:MM --report-to URL [--root PATH]... [--budget 2TB] ' \
                       '[--cycle 90d]'
            o.on('--root PATH', 'A storage root; repeat for each. Default: OCFL_ROOTS') { |path| @roots << path }
            o.on('--until TIME', 'Stop at this UTC time of day (HH:MM) or ISO 8601 time') do |value|
              @deadline = self.class.deadline(value, @clock.call)
            end
            o.on('--budget SIZE', 'Stop after hashing this much, e.g. 500GB') { |value| @budget = self.class.bytes(value) }
            o.on('--cycle DURATION', "Re-check an object this long after its last check. Default: #{DEFAULT_CYCLE}") do |value|
              @cycle = self.class.seconds(value)
            end
            o.on('--report-to URL', 'Atlas base URL') { |url| @report_to = url }
          end
        end

        def missing_setting
          return 'give --until and --report-to' if @deadline.nil? || @report_to.nil?
          return 'set FIXITY_TOKEN or FIXITY_TOKEN_FILE' if token.to_s.empty?

          'give --root or OCFL_ROOTS' if roots.empty?
        end

        def roots
          @roots.empty? ? @env.fetch('OCFL_ROOTS', '').split(':') : @roots
        end

        def client
          Client.new(base_url: @report_to, token: token, nuid: @env.fetch('FIXITY_NUID', '000000098'))
        end

        # A file, so a Docker or Swarm secret can supply it without an env var.
        def token
          @token ||= if @env['FIXITY_TOKEN_FILE'].to_s.empty?
                       @env['FIXITY_TOKEN']
                     else
                       File.read(@env['FIXITY_TOKEN_FILE']).strip
                     end
        end

        def usage(message)
          @out.puts("ocfl-fixity-sweep: #{message}")
          @out.puts(options.banner)
          USAGE_ERROR
        end
    end
  end
end
