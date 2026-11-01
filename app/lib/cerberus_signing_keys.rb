# frozen_string_literal: true

# Cerberus's public keyset, `kid => key`, parsed from credentials and reused
# while the configured value is unchanged. See docs/authentication.md.
module CerberusSigningKeys
  @parsed = [nil, {}.freeze]

  def self.current
    raw = Rails.application.credentials.cerberus_signing_keys
    return {} if raw.blank?

    # Keyed on the raw value, not memoized once: a rotated keyset, or a spec's
    # stub, compares unequal and is parsed afresh.
    cached_raw, keys = @parsed
    return keys if cached_raw == raw

    keys = raw.to_h.to_h { |kid, pem| [kid.to_s, OpenSSL::PKey.read(pem)] }.freeze
    @parsed = [raw, keys].freeze
    keys
  rescue OpenSSL::PKey::PKeyError
    {}
  end
end
