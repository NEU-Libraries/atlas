# frozen_string_literal: true

# Element order is fixed by OAI-PMH.xsd: name, baseURL, version, adminEmail,
# earliestDatestamp, deletedRecord, granularity, then descriptions.
#
# earliestDatestamp must not be blank, so an empty repository reports the
# epoch. A live one reports the oldest harvestable record's datestamp, which
# is the earliest `from` worth sending.
xml.Identify do
  xml.repositoryName OAI.config.repository_name
  xml.baseURL OAI.config.base_url
  xml.protocolVersion OAI::PROTOCOL_VERSION
  xml.adminEmail OAI.config.admin_email
  xml.earliestDatestamp(@earliest_datestamp.presence || Time.at(0).utc.iso8601)
  xml.deletedRecord OAI::DELETED_RECORD
  xml.granularity OAI::GRANULARITY

  # The oai-identifier description — where repositoryIdentifier actually
  # lives. v1 advertised an empty one and a sampleIdentifier of ":13900".
  xml.description do
    xml.tag!('oai-identifier',
             'xmlns'              => 'http://www.openarchives.org/OAI/2.0/oai-identifier',
             'xmlns:xsi'          => 'http://www.w3.org/2001/XMLSchema-instance',
             'xsi:schemaLocation' => 'http://www.openarchives.org/OAI/2.0/oai-identifier ' \
                                     'http://www.openarchives.org/OAI/2.0/oai-identifier.xsd') do
      xml.scheme 'oai'
      xml.repositoryIdentifier OAI.config.repository_identifier
      xml.delimiter ':'
      xml.sampleIdentifier OAI.identifier_for(OAI::SAMPLE_NOID)
    end
  end
end
