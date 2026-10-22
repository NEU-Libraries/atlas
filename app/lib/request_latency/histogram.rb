# frozen_string_literal: true

module RequestLatency
  # The bucket arithmetic, apart from the Redis traffic.
  module Histogram
    # Upper edges in milliseconds; slower lands in `inf`. The same edges as
    # Cerberus's LatencyHistogram, so the two rows on its health card compare.
    BUCKETS_MS = [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10_000].freeze
    FIELDS = (BUCKETS_MS.map { |edge| "le_#{edge}" } + ['le_inf']).freeze

    module_function

    def bucket_for(duration_ms)
      edge = BUCKETS_MS.find { |limit| duration_ms <= limit }
      edge ? "le_#{edge}" : 'le_inf'
    end

    def counts(fields) = FIELDS.map { |field| fields[field].to_i }

    # Linear interpolation inside the bucket that holds the rank. The open top
    # bucket has no upper edge, so a rank there reports the last edge.
    def percentile(counts, quantile)
      total = counts.sum
      return nil if total.zero?

      rank = quantile * total
      seen = 0
      counts.each_with_index do |count, index|
        next seen += count if seen + count < rank

        lower = index.zero? ? 0 : BUCKETS_MS[index - 1]
        upper = BUCKETS_MS[index] || BUCKETS_MS.last
        return (lower + ((upper - lower) * (rank - seen) / count)).round
      end
    end

    # Fields are `<controller#action>|<bucket>`.
    def slowest(per_action, limit)
      by_action = Hash.new { |hash, action| hash[action] = Hash.new(0) }
      per_action.each do |field, count|
        action, bucket = field.split('|', 2)
        by_action[action][bucket] += count.to_i
      end

      rows = by_action.map do |action, buckets|
        bucket_counts = counts(buckets)
        { action: action, calls: bucket_counts.sum, p95_ms: percentile(bucket_counts, 0.95) }
      end
      rows.sort_by { |row| [-row[:p95_ms], -row[:calls], row[:action]] }.first(limit)
    end
  end
end
