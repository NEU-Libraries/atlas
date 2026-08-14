# frozen_string_literal: true

module OAI
  # The cursor a harvester hands back to continue a list — base64url JSON,
  # HMAC-signed.
  #
  # Signing is not decoration. The token carries a Solr cursorMark and a set
  # noid that flow straight into a query, so an altered or truncated token
  # must come back as `badResumptionToken`, never as a 500 or an injected
  # filter clause. v1 instead recovered the set from the token with a regex
  # against the literal string `mods`, which returned nil for every other
  # metadataPrefix.
  #
  # base64url with no padding, rather than ActiveSupport::MessageVerifier's
  # standard base64: a `+` in a query string decodes to a space, and a
  # resumptionToken travels as a query argument.
  #
  # The token is stateless — no server-side cursor table — so a harvester may
  # resume a list at any time. `expirationDate` is therefore not advertised.
  module ResumptionToken
    # Everything a list verb needs to resume itself. metadataPrefix, from,
    # until and set are frozen at the first request: OAI-PMH forbids a
    # harvester from changing them mid-list, and re-reading them from the
    # token is what enforces that.
    FIELDS = %w[metadataPrefix from until set cursorMark cursor completeListSize].freeze

    class InvalidToken < StandardError; end

    def self.encode(payload)
      body = base64(JSON.generate(payload.slice(*FIELDS)))
      "#{body}.#{signature(body)}"
    end

    # Raises InvalidToken on anything that is not a token this repository
    # signed: a wrong shape, a bad signature, or a body that is not a JSON
    # object. The caller turns that into badResumptionToken.
    def self.decode(token)
      body, sig = token.to_s.split('.', 2)
      raise InvalidToken, 'malformed token' if body.blank? || sig.blank?
      raise InvalidToken, 'bad signature' unless
        ActiveSupport::SecurityUtils.secure_compare(sig, signature(body))

      parsed = JSON.parse(Base64.urlsafe_decode64(body))
      raise InvalidToken, 'not an object' unless parsed.is_a?(Hash)

      parsed.slice(*FIELDS)
    rescue ArgumentError, JSON::ParserError => e
      raise InvalidToken, e.message
    end

    def self.signature(body)
      base64(OpenSSL::HMAC.digest('SHA256', key, body))
    end

    # Derived rather than the raw secret_key_base, so this token's key is not
    # the key any other Rails subsystem signs with.
    def self.key
      @key ||= Rails.application.key_generator.generate_key('oai/resumption_token', 32)
    end

    def self.base64(value)
      Base64.urlsafe_encode64(value, padding: false)
    end

    private_class_method :signature, :key, :base64
  end
end
