# frozen_string_literal: true

module METSBuilder
  METS_NS  = 'http://www.loc.gov/METS/'
  XLINK_NS = 'http://www.w3.org/1999/xlink'
  DRS_NS   = 'https://repository.neu.edu/spec/v1'

  def mets_template
    builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
      xml.mets('xmlns' => METS_NS,
               'xmlns:xlink' => XLINK_NS,
               'xmlns:drs' => DRS_NS,
               'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance',
               'xsi:schemaLocation' =>
                 "#{METS_NS} http://www.loc.gov/standards/mets/mets.xsd",
               'OBJID' => mets_objid_for_template,
               'LABEL' => mets_label_for_template) do
        xml.metsHdr('CREATEDATE' => Time.now.utc.iso8601) do
          xml.agent('ROLE' => 'CREATOR', 'TYPE' => 'OTHER') do
            xml.name 'Atlas'
          end
        end
        xml.fileSec do
          xml.fileGrp
        end
        xml.structMap('TYPE' => 'logical') do
          xml.div('TYPE' => 'fileSet')
        end
      end
    end
    builder.to_xml
  end

  private

    def mets_objid_for_template
      respond_to?(:noid) && noid.present? ? "urn:neu-drs:#{noid}" : ''
    end

    def mets_label_for_template
      respond_to?(:type) && type.present? ? type : 'FileSet'
    end
end
