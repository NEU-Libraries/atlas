# frozen_string_literal: true

module MODSBuilder
  # The document a resource is minted with when the caller supplies no MODS.
  # It carries only what a new record genuinely needs: the primary titleInfo
  # the deposit seeds a title into, and the `hdl` identifier HandleMinter
  # fills on completion. Every other field arrives when a curator supplies a
  # value.
  #
  # Empty placeholder elements are NOT seeded. They were a v1 requirement —
  # OM resolved a terminology term to an XPath and could only write through a
  # node that already existed — and the merge that replaced it (Cerberus's
  # MODSMerge, over NEU::MODS) creates every node it needs on demand. A seeded
  # `<name>` stub is worse than absent: it has no `<role>`, so the gem's
  # editable-creator selector skips it, the merge cannot remove it, and a
  # curator's new creator lands after it — leaving a record that reads as
  # having blank creators.
  #
  # The namespace declarations stay whether or not this document uses them, so
  # a prefix a curator or loader adds later is already bound.
  def mods_template
    builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
      xml.mods('xmlns:drs' => 'https://repository.neu.edu/spec/v1', 'xmlns:mods' => 'http://www.loc.gov/mods/v3', 'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance',
               'xsi:schemaLocation' => 'http://www.loc.gov/mods/v3 http://www.loc.gov/standards/mods/v3/mods-3-8.xsd',
               'xmlns:niec' => 'http://repository.neu.edu/schema/niec',
               'xmlns:dcterms' => 'http://purl.org/dc/terms/',
               'xmlns:dwc' => 'http://rs.tdwg.org/dwc/terms/',
               'xmlns:dwr' => 'http://rs.tdwg.org/dwc/xsd/simpledarwincore/') do
        xml.parent.namespace = xml.parent.namespace_definitions.find { |ns| ns.prefix == 'mods' }
        xml.titleInfo('usage' => 'primary') do
          xml.title ''
        end
        xml.identifier('type' => 'hdl', 'displayLabel' => 'Permanent URL')
      end
    end
    builder.to_xml
  end
end
