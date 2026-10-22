# frozen_string_literal: true

# Times each request from the top of Atlas's Rack stack until the app returns,
# and hands the figure to RequestLatency. See docs/read-performance.md.
#
# Lives in lib/ and is required by its initializer, because the middleware
# stack is built once at boot and must not hold a reloadable constant.
# RequestLatency itself is looked up per request, so it still reloads.
class RequestTiming
  def initialize(app)
    @app = app
  end

  def call(env)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = @app.call(env)
    record(env, started, response.first)
    response
  rescue StandardError
    record(env, started, 500)
    raise
  end

  private

    # Timing must never fail the request it timed.
    def record(env, started, status)
      elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
      route = env['action_dispatch.request.path_parameters']
      RequestLatency.record_request(elapsed_ms, route: route, status: status)
    rescue StandardError => e
      Rails.logger.warn("[latency] could not record a request: #{e.class}: #{e.message}")
    end
end
