# frozen_string_literal: true

# The OAI-PMH envelope every response shares. The verb template supplies only
# the payload element, which arrives here already serialized — `xml <<`
# appends it without escaping.
#
# <request> reports the configured baseURL, never the site root: a harvester
# that trusts baseURL follows it, and v1 sent them to the wrong host. Its
# attributes echo what the harvester sent, except after badVerb / badArgument,
# where the protocol requires none (OAI::Request#echo_attributes).
xml.instruct!
xml.tag!('OAI-PMH',
         'xmlns'              => 'http://www.openarchives.org/OAI/2.0/',
         'xmlns:xsi'          => 'http://www.w3.org/2001/XMLSchema-instance',
         'xsi:schemaLocation' => 'http://www.openarchives.org/OAI/2.0/ ' \
                                 'http://www.openarchives.org/OAI/2.0/OAI-PMH.xsd') do
  xml.responseDate Time.current.utc.iso8601
  xml.request OAI.config.base_url, @oai.echo_attributes
  xml << yield
end
