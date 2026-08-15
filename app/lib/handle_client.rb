# frozen_string_literal: true

require 'net/http'

# Speaks the Handle.Net JSON REST API (Technical Manual §14) so a Work can
# carry a citable persistent identifier. This is the only outbound HTTP call
# Atlas makes, which is why it is stdlib Net::HTTP and not a client gem: one
# dependency-free class, and direct control over the TLS handling below.
#
# Every failure — a refused connection, a timeout, a bad status, a Handle
# error code — surfaces as HandleClient::Error, so the caller has one thing
# to rescue and minting can never leak a transport exception into a request.
class HandleClient
  class Error < StandardError; end

  # Where the bootstrap admin record keeps its HS_SECKEY (see the seed in
  # cerberus-handles), and the conventional index of a handle's URL value.
  ADMIN_INDEX = 300
  URL_INDEX   = 1

  # A handle server answering at all is fast; one that is wedged must not
  # hold a finalize open. Minting is best-effort at the call site, so a short
  # ceiling is better than a complete request that hangs.
  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 5

  # Handle's own status vocabulary, which rides inside a 200 body rather than
  # the HTTP status: 1 is success, 100 is "no such handle".
  RC_SUCCESS   = 1
  RC_NOT_FOUND = 100

  def initialize(server_url: ENV.fetch('HANDLE_SERVER_URL', nil),
                 prefix: ENV.fetch('HANDLE_PREFIX', nil),
                 admin_secret: ENV.fetch('HANDLE_ADMIN_SECRET', nil),
                 verify_ssl: ENV.fetch('HANDLE_SSL_VERIFY', 'true') != 'false')
    @server_url   = server_url.presence
    @prefix       = prefix.presence
    @admin_secret = admin_secret.presence
    @verify_ssl   = verify_ssl
  end

  attr_reader :prefix

  # Minting stays inert until all three are set, mirroring the empty-keyset
  # rule on the signed-assertion auth path: an unconfigured deployment does
  # nothing rather than failing loudly on a path that does not need it.
  def configured?
    @server_url.present? && @prefix.present? && @admin_secret.present?
  end

  # Create or re-point "<prefix>/<suffix>". Idempotent by handle name — the
  # Handle server replaces the record's values, so a re-mint corrects the URL
  # instead of creating a second record. Returns the full handle string.
  def mint(suffix, url:)
    handle = "#{@prefix}/#{suffix}"
    request = Net::HTTP::Put.new(path_for(handle))
    request['Content-Type']  = 'application/json'
    request['Authorization'] = authorization
    request.body = { values: [url_value(url)] }.to_json
    perform(request)
    handle
  end

  # The URL a handle currently points at, or nil when the server has no such
  # record. Unauthenticated: resolution is a public read.
  def resolve(handle)
    body = perform(Net::HTTP::Get.new(path_for(handle)), allow: [RC_SUCCESS, RC_NOT_FOUND])
    return nil if body['responseCode'] == RC_NOT_FOUND

    Array(body['values']).find { |v| v['type'] == 'URL' }&.dig('data', 'value')
  end

  def delete(handle)
    request = Net::HTTP::Delete.new(path_for(handle))
    request['Authorization'] = authorization
    perform(request, allow: [RC_SUCCESS, RC_NOT_FOUND])
    handle
  end

  private

    def path_for(handle)
      # The prefix/suffix slash is a real path separator here, so the handle
      # goes in unescaped — /api/handles/DRSDEV/abc123.
      "/api/handles/#{handle}"
    end

    # HTTP Basic, with one Handle-specific twist: the username is
    # "{index}%3A{handle}", where the colon separating index from handle is
    # percent-encoded so Basic auth cannot read it as its own separator. Built
    # by hand rather than through Net::HTTP#basic_auth to keep that intact.
    def authorization
      credential = Base64.strict_encode64("#{ADMIN_INDEX}%3A#{@prefix}/ADMIN:#{@admin_secret}")
      "Basic #{credential}"
    end

    # Only the URL value. The bootstrap admin is a server admin with
    # full access, so it can still update and delete a record that carries no
    # HS_ADMIN value of its own — and this is the shape verified end-to-end
    # against the dev server. A GHR-registered production prefix will want an
    # HS_ADMIN value here as well; add it with the repoint, not before.
    def url_value(url)
      { index: URL_INDEX, type: 'URL', data: { format: 'string', value: url } }
    end

    # The Handle REST API mirrors its own status into the HTTP status — a "no
    # such handle" (responseCode 100) arrives as a 404, and a refused
    # credential as a 401 — so the responseCode is the authority here and a
    # bare HTTP status only decides a reply that carries no Handle code at
    # all (a proxy error, say).
    def perform(request, allow: [RC_SUCCESS])
      response = dispatch(request)
      body     = parse(response)
      code     = body['responseCode']

      if code.nil?
        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "handle server returned HTTP #{response.code}: #{response.body}"
        end
      elsif allow.exclude?(code)
        raise Error, "handle server returned responseCode #{code}: #{response.body}"
      end

      body
    end

    def dispatch(request)
      uri  = URI.parse(@server_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      configure_tls(http, uri)
      http.request(request)
    rescue Timeout::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError, SocketError => e
      raise Error, "handle server unreachable at #{@server_url}: #{e.class} #{e.message}"
    end

    # The dev/staging server presents a self-signed certificate whose subject
    # is CN=anonymous with no subjectAltName, so no hostname can ever verify
    # against it and adding it to a CA bundle does not help. HANDLE_SSL_VERIFY
    # turns the check off for that host only; it defaults to on, so a
    # production server with a real certificate is verified normally.
    def configure_tls(http, uri)
      return unless uri.scheme == 'https'

      http.use_ssl     = true
      http.verify_mode = @verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
    end

    def parse(response)
      # A refused credential comes back as a bare 401 with no body at all, so
      # an empty one is not a parse failure — it just carries no Handle code,
      # and the HTTP status above is left to speak for it.
      return {} if response.body.blank?

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error, "handle server returned HTTP #{response.code} with an unparseable body: " \
                   "#{response.body.to_s.truncate(200)}"
    end
end
