# frozen_string_literal: true

# The OAI-PMH provider's shared vocabulary. Verb handlers live in
# OAIController, response bodies in app/views/oai. See docs/oai.md.
module OAI
  # `mods` is the one that matters: Boston Public Library consumes it. `oai_dc`
  # ships because the protocol requires it.
  FORMATS = {
    'oai_dc' => { schema:    'http://www.openarchives.org/OAI/2.0/oai_dc.xsd',
                  namespace: 'http://www.openarchives.org/OAI/2.0/oai_dc/' },
    'mods'   => { schema:    'http://www.loc.gov/standards/mods/v3/mods-3-8.xsd',
                  namespace: 'http://www.loc.gov/mods/v3' }
  }.freeze

  # A purged record leaves no Solr document at all, so this repository cannot
  # promise that every deletion is reported. `transient` is the honest word.
  DELETED_RECORD = 'transient'

  # A repository advertising seconds must ALSO accept YYYY-MM-DD, and
  # OAI::Request does.
  GRANULARITY = 'YYYY-MM-DDThh:mm:ssZ'

  PROTOCOL_VERSION = '2.0'

  # Identify advertises the SHAPE of an identifier, so this is illustrative
  # rather than live.
  SAMPLE_NOID = 'cj82kf90c'

  # baseURL differs per deployment, and a harvester that trusts it follows it
  # -- an Identify naming the site root instead of the endpoint finds nothing.
  def self.config
    @config ||= Rails.application.config_for(:oai)
  end

  # oai:<repositoryIdentifier>:<noid>.
  def self.identifier_for(noid)
    "#{identifier_prefix}#{noid}"
  end

  # nil when the identifier is not this repository's; the caller answers that
  # with idDoesNotExist.
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
