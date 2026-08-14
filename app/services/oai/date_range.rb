# frozen_string_literal: true

module OAI
  # The `from` / `until` pair of a list request: parsed, validated, and
  # normalized to UTC.
  #
  # Its own object because the rules interact and none of them is obvious.
  # The two bounds must share one granularity — a day-level `from` with a
  # second-level `until` is badArgument, not something to coerce — and a day
  # covers the whole of that day, so `until=2026-02-10` includes a record
  # stamped that afternoon. A bound that reads backwards denotes nothing, so
  # it is an error rather than an empty list.
  #
  # Messages accumulate in #errors; the caller reports each as badArgument.
  class DateRange
    DAY    = /\A\d{4}-\d{2}-\d{2}\z/
    SECOND = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

    attr_reader :from, :until_time, :errors

    def initialize(from:, until_time:)
      @raw_from  = from
      @raw_until = until_time
      @errors    = []
      parse
    end

    private

      def parse
        return if @raw_from.blank? && @raw_until.blank?
        return unless well_formed? && matched_granularity?

        @from       = to_time(@raw_from)
        @until_time = to_time(@raw_until, end_of_day: true)
        check_order
      end

      def well_formed?
        legal?('from', @raw_from) && legal?('until', @raw_until)
      end

      # The shape has to match one of the two granularities AND name a real
      # instant — 2026-02-31 passes the pattern and is still not a date.
      def legal?(key, value)
        return true if value.blank?
        return true if (value.match?(DAY) || value.match?(SECOND)) && parseable?(value)

        @errors << "the #{key} argument is not a legal UTCdatetime"
        false
      end

      # Only Date.iso8601 is strict about the calendar: Time.parse rolls
      # 2026-02-31 forward to March 3 and answers a nonsense request with a
      # plausible-looking list. Time.iso8601 then catches an out-of-range
      # clock time, which the pattern alone lets through.
      def parseable?(value)
        Date.iso8601(value[0, 10])
        Time.iso8601(value) if value.match?(SECOND)
        true
      rescue ArgumentError # Date::Error is one
        false
      end

      def matched_granularity?
        return true if @raw_from.blank? || @raw_until.blank?
        return true if @raw_from.match?(DAY) == @raw_until.match?(DAY)

        @errors << 'from and until must use the same granularity'
        false
      end

      def check_order
        return unless @from && @until_time && @from > @until_time

        @errors << 'from must not be later than until'
      end

      def to_time(value, end_of_day: false)
        return nil if value.blank?

        time = Time.parse(value).utc
        end_of_day && value.match?(DAY) ? time.end_of_day : time
      end
  end
end
