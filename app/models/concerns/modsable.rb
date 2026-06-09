# frozen_string_literal: true

module Modsable
  extend ActiveSupport::Concern
  include MODSBuilder
  include MODSToJson
  include FileHelper

  def mods
    @mods ||= Metadata::MODS.find_by(valkyrie_id: noid)
  end

  def mods_xml
    return mods_template if mods_blob&.file.blank?

    Nokogiri::XML(mods_blob.file.read, &:noblanks).to_s
  end

  def mods_xml=(raw_xml)
    blob = mods_blob || create_mods_blob
    blob.file_identifiers += [create_file(write_tmp_xml(raw_xml), blob, 'descMetadata.xml').version_id]
    Atlas.persister.save(resource: blob)

    self.mods_json = raw_xml
  end

  def mods_blob
    descriptive_metadata_file_set&.files&.first
  end

  def mods_json=(raw_xml)
    record = Metadata::MODS.find_or_create_by(valkyrie_id: noid)
    record.json_attributes = convert_xml_to_json(raw_xml)
    record.save!
    @mods = record
  end

  private

    def descriptive_metadata_file_set
      children.find { |fs| fs.type == Classification.descriptive_metadata.name }
    end

    def create_mods_blob
      fs = descriptive_metadata_file_set
      blob = Atlas.persister.save(resource: Blob.new(use: Role.descriptive_metadata.name))
      fs.member_ids += [blob.id]
      fs = Atlas.persister.save(resource: fs)
      blob.write_preservation_envelope!
      fs.write_preservation_envelope!
      blob
    end

    def write_tmp_xml(raw_xml)
      xml_path = Rails.root.join('tmp', "#{Time.now.to_f.to_s.gsub!('.', '-')}.xml").to_s
      File.write(xml_path, raw_xml)
      xml_path
    end
end
