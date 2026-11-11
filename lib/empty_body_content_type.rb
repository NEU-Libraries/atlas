# frozen_string_literal: true

# A response with no body names no media type. Rails labels a bare `head`,
# such as a 404 or a 416, with the request's format, so a client that parses
# by Content-Type tries to parse nothing as JSON. See docs/error-contract.md.
#
# Content-Length is set by the server, outside this stack, so the body itself
# is checked. Only a buffered body answers to_ary; a streamed one, such as a
# file's bytes, passes through unread. Rack requires the original body to be
# closed once to_ary has replaced it, as Rack::ETag above does.
class EmptyBodyContentType
  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)
    return [status, headers, body] unless body.respond_to?(:to_ary)

    parts = body.to_ary
    body.close if body.respond_to?(:close)
    headers.delete('content-type') if parts.all?(&:empty?)
    [status, headers, parts]
  end
end
