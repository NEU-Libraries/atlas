# frozen_string_literal: true

module MODSToJson
  def convert_xml_to_json(raw_xml)
    record = Metadata::MODS.new
    record.assign_attributes(NEU::MODS::Document.parse(raw_xml).to_h)
    record.json_attributes
  end
end
