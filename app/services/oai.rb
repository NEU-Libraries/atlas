# frozen_string_literal: true

# The OAI-PMH provider's shared vocabulary: the deployment settings and the
# identifier scheme. The verb handlers live in OAIController, the response
# bodies in app/views/oai.
module OAI
  # The two metadata formats this repository disseminates. `mods` is the one
  # that matters — Boston Public Library consumes it for Digital Commonwealth.
  # `oai_dc` ships because the protocol requires every repository to support
  # it, and is a documented crosswalk off the JSON access copy (OAI::DublinCore).
  FORMATS = {
    'oai_dc' => { schema:    'http://www.openarchives.org/OAI/2.0/oai_dc.xsd',
                  namespace: 'http://www.openarchives.org/OAI/2.0/oai_dc/' },
    'mods'   => { schema:    'http://www.loc.gov/standards/mods/v3/mods-3-5.xsd',
                  namespace: 'http://www.loc.gov/mods/v3' }
  }.freeze

  # Withdrawn records come back as <header status="deleted">, but a purged one
  # leaves no Solr document at all, so this repository cannot promise a
  # harvester that every deletion is reported. `transient` is the honest
  # declaration. (v1 declared the same value, but only because it was the gem
  # default — it never emitted a deleted header at all.)
  DELETED_RECORD = 'transient'

  # The finest granularity accepted and advertised. A repository advertising
  # seconds must also accept YYYY-MM-DD, and OAI::Request does.
  GRANULARITY = 'YYYY-MM-DDThh:mm:ssZ'

  PROTOCOL_VERSION = '2.0'

  # Identify advertises the *shape* of an identifier, so this is an
  # illustrative NOID rather than a live one. v1 advertised `:13900`, which is
  # not an OAI identifier at all.
  SAMPLE_NOID = 'cj82kf90c'

  # baseURL differs per deployment, and v1's single worst defect was an
  # Identify that advertised the site root instead of the endpoint — a
  # harvester that trusts baseURL follows it and finds nothing.
  def self.config
    @config ||= Rails.application.config_for(:oai)
  end

  # oai:<repositoryIdentifier>:<noid>. v1 emitted `/neu:329563` — not a URI at
  # all, because record_prefix was empty — which is one reason the cut-over
  # needs a full re-harvest rather than an incremental one.
  def self.identifier_for(noid)
    "#{identifier_prefix}#{noid}"
  end

  # The NOID inside an OAI identifier, or nil if the identifier does not
  # belong to this repository. The caller answers nil with idDoesNotExist.
  def self.noid_from(identifier)
    value = identifier.to_s
    return nil unless value.start_with?(identifier_prefix)

    value.delete_prefix(identifier_prefix).presence
  end

  def self.identifier_prefix
    "oai:#{config.repository_identifier}:"
  end
  private_class_method :identifier_prefix
end
