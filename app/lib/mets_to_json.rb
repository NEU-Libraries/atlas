# frozen_string_literal: true

module METSToJson
  include METSExtraction

  def convert_mets_xml_to_json(raw_xml)
    doc = Nokogiri::XML(raw_xml, &:noblanks)
    record = Metadata::METS.new

    record.created_at_iso  = extract_mets_created_at(doc)
    record.agent           = extract_mets_agent(doc)
    record.files           = extract_mets_files(doc)
    record.structure_label = extract_mets_structure_label(doc)
    record.pages           = extract_mets_pages(doc)

    record.json_attributes
  end
end
