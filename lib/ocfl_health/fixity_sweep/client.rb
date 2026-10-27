# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module OcflHealth
  class FixitySweep
    # Atlas over plain HTTP, authenticated as the :fixity_checker fixture.
    class Client
      # Atlas refused the checker, or could not be reached: a maintenance
      # window, a bad credential or a network fault. The run stops rather than
      # hashing objects it could not record.
      class Refused < StandardError
      end

      STOP_STATUSES = [401, 403, 503].freeze

      def initialize(base_url:, token:, nuid:, timeout: 30)
        @base    = URI(base_url.end_with?('/') ? base_url : "#{base_url}/")
        @token   = token
        @nuid    = nuid
        @timeout = timeout
      end

      def due(before:, limit:)
        uri = URI.join(@base, 'fixity_checks/due')
        uri.query = URI.encode_www_form(checked_before: before.iso8601, limit: limit)
        response = send_request(Net::HTTP::Get.new(uri))
        raise Refused, "due list answered #{response.code}" unless response.code == '200'

        JSON.parse(response.body).fetch('due')
      end

      # [status, error code or message]. A refusal raises; a 404 or a 422 is
      # one object's problem and is returned for the sweep to pass over.
      def record(body)
        request = Net::HTTP::Post.new(URI.join(@base, 'fixity_checks'))
        request['Content-Type'] = 'application/json'
        request.body = JSON.dump(body)
        response = send_request(request)
        raise Refused, "POST /fixity_checks answered #{response.code}" if STOP_STATUSES.include?(response.code.to_i)

        [response.code.to_i, error_detail(response)]
      end

      private

        def send_request(request)
          request['Authorization'] = "Bearer #{@token}"
          request['User'] = "NUID #{@nuid}"
          Net::HTTP.start(request.uri.host, request.uri.port, use_ssl: request.uri.scheme == 'https',
                                                              open_timeout: @timeout, read_timeout: @timeout) do |http|
            http.request(request)
          end
        rescue SystemCallError, IOError, Timeout::Error, SocketError => e
          raise Refused, "Atlas unreachable: #{e.class}: #{e.message}"
        end

        def error_detail(response)
          JSON.parse(response.body.to_s)['error']
        rescue JSON::ParserError
          response.body.to_s[0, 200]
        end
    end
  end
end
