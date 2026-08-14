# frozen_string_literal: true

# An oai_dc:dc payload from an { element => [values] } hash — used both for a
# record's crosswalk (OAI::DublinCore) and for a Set's description, which the
# protocol also wraps in oai_dc.
xml.tag!('oai_dc:dc',
         'xmlns:oai_dc'       => 'http://www.openarchives.org/OAI/2.0/oai_dc/',
         'xmlns:dc'           => 'http://purl.org/dc/elements/1.1/',
         'xmlns:xsi'          => 'http://www.w3.org/2001/XMLSchema-instance',
         'xsi:schemaLocation' => 'http://www.openarchives.org/OAI/2.0/oai_dc/ ' \
                                 'http://www.openarchives.org/OAI/2.0/oai_dc.xsd') do
  dc.each do |element, values|
    Array(values).each { |value| xml.tag!("dc:#{element}", value) }
  end
end
