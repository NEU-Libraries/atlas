# frozen_string_literal: true

# GET /metrics/latency: Atlas's own request latency. See
# docs/read-performance.md.
class MetricsController < ApplicationController
  MAX_MINUTES = RequestLatency::RETENTION.in_minutes.to_i

  # The figures live in Redis. Handled here rather than in BackendUnavailable,
  # because everywhere else a Redis outage only costs the response cache.
  rescue_from Redis::BaseError do |exception|
    render_backend_unavailable('cache', exception)
  end

  def latency
    authorize! :read_metrics, :latency

    @minutes = params.fetch(:minutes, RequestLatency::WINDOW_MINUTES).to_i.clamp(1, MAX_MINUTES)
    @latency = RequestLatency.summary(minutes: @minutes)
    render 'metrics/latency'
  end
end
