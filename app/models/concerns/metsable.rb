# frozen_string_literal: true

module Metsable
  extend ActiveSupport::Concern
  include METSBuilder
  include METSToJson
  include FileHelper

  def mets
    @mets ||= Metadata::METS.find_or_create_by(valkyrie_id: noid)
  end

  def mets_xml
    return mets_template if mets_blob&.file.blank?

    Nokogiri::XML(mets_blob.file.read, &:noblanks).to_s
  end

  def mets_xml=(raw_xml)
    blob = mets_blob || create_mets_blob
    blob.file_identifiers += [create_file(write_tmp_mets_xml(raw_xml), blob, 'mets.xml').version_id]
    Atlas.persister.save(resource: blob)

    self.mets_json = raw_xml
  end

  def mets_blob
    structural_metadata_file_set&.files&.first
  end

  def mets_json=(raw_xml)
    mets_json = mets
    mets_json.json_attributes = convert_mets_xml_to_json(raw_xml)
    mets_json.save!
  end

  private

    def structural_metadata_file_set
      children.find { |fs| fs.type == Classification.structural_metadata.name }
    end

    def create_mets_blob
      fs = structural_metadata_file_set
      blob = Atlas.persister.save(resource: Blob.new)
      fs.member_ids += [blob.id]
      Atlas.persister.save(resource: fs)
      blob
    end

    def write_tmp_mets_xml(raw_xml)
      xml_path = Rails.root.join('tmp', "#{Time.now.to_f.to_s.gsub!('.', '-')}-mets.xml").to_s
      File.write(xml_path, raw_xml)
      xml_path
    end
end
