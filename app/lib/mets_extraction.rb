# frozen_string_literal: true

module METSExtraction
  def extract_mets_created_at(doc)
    doc.at_xpath('//m:metsHdr/@CREATEDATE', m: METSBuilder::METS_NS)&.value
  end

  def extract_mets_agent(doc)
    doc.at_xpath('//m:metsHdr/m:agent/m:name', m: METSBuilder::METS_NS)&.text&.squish
  end

  def extract_mets_files(doc)
    doc.xpath('//m:fileSec//m:file', m: METSBuilder::METS_NS).map do |node|
      Metadata::Fields::FileEntry.new(
        id:        node['ID'].to_s,
        mime_type: node['MIMETYPE'].to_s,
        use:       node['USE'].to_s
      )
    end
  end

  def extract_mets_structure_label(doc)
    doc.at_xpath('//m:structMap/m:div/@LABEL', m: METSBuilder::METS_NS)&.value ||
      doc.at_xpath('//m:structMap/m:div/@TYPE', m: METSBuilder::METS_NS)&.value
  end

  # Page divs from a Work-level physical structMap; empty for the
  # FileSet-level logical maps. The mptr href carries urn:neu-drs:<noid>.
  def extract_mets_pages(doc)
    doc.xpath('//m:structMap[@TYPE="physical"]//m:div[@TYPE="page"]',
              m: METSBuilder::METS_NS).map { |node| page_entry_for(node) }
  end

  private

    def page_entry_for(node)
      href = node.at_xpath('m:mptr/@xlink:href',
                           'm' => METSBuilder::METS_NS, 'xlink' => METSBuilder::XLINK_NS)&.value
      Metadata::Fields::PageEntry.new(
        noid:  href.to_s.delete_prefix('urn:neu-drs:'),
        order: node['ORDER']&.to_i,
        label: node['LABEL'].to_s
      )
    end
end
