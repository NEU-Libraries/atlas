# frozen_string_literal: true

module OAI
  # The cursor a harvester hands back to continue a list: base64url JSON,
  # HMAC-signed. See docs/oai.md.
  #
  # Signing is not decoration -- the token carries a Solr cursorMark and a set
  # noid that flow straight into a query, so a tampered token must come back as
  # badResumptionToken and never as an injected filter clause.
  #
  # base64url with NO padding, not MessageVerifier's standard base64: a `+` in
  # a query string decodes to a space, and this travels as a query argument.
  #
  # Stateless, so a harvester may resume at any time and expirationDate is not
  # advertised.
  module ResumptionToken
    # metadataPrefix, from, until and set are frozen at the first request:
    # OAI-PMH forbids changing them mid-list, and re-reading them from the
    # token is what enforces it.
    FIELDS = %w[metadataPrefix from until set cursorMark cursor completeListSize].freeze

    class InvalidToken < StandardError; end

    def self.encode(payload)
      body = base64(JSON.generate(payload.slice(*FIELDS)))
      "#{body}.#{signature(body)}"
    end

    # The caller turns InvalidToken into badResumptionToken.
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

    # Derived, so this token's key is not one another subsystem signs with.
    def self.key
      @key ||= Rails.application.key_generator.generate_key('oai/resumption_token', 32)
    end

    def self.base64(value)
      Base64.urlsafe_encode64(value, padding: false)
    end

    private_class_method :signature, :key, :base64
  end
end
