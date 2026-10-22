# frozen_string_literal: true

json.window_minutes @minutes
json.calls          @latency.calls
json.server_errors  @latency.server_errors
json.mean_ms        @latency.mean_ms
json.p50_ms         @latency.p50_ms
json.p95_ms         @latency.p95_ms
json.p99_ms         @latency.p99_ms
json.slowest_actions @latency.slowest_actions do |row|
  json.action row[:action]
  json.calls  row[:calls]
  json.p95_ms row[:p95_ms]
end
