# frozen_string_literal: true

module Metsable
  extend ActiveSupport::Concern
  include METSBuilder
  include METSToJson
  include FileHelper

  def mets
    return @mets if defined?(@mets)

    @mets = Metadata::METS.find_by(valkyrie_id: noid)
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

  # The METS blob is a direct member of self.member_ids, distinguished by
  # its `use` role marker — not a sub-FileSet.
  def mets_blob
    files.compact.find { |b| b.use == Role.structural_metadata.name }
  end

  def mets_json=(raw_xml)
    record = Metadata::METS.find_or_create_by(valkyrie_id: noid)
    record.json_attributes = convert_mets_xml_to_json(raw_xml)
    record.save!
    @mets = record
  end

  private

    def create_mets_blob
      blob = Atlas.persister.save(resource: Blob.new(use: Role.structural_metadata.name))
      self.member_ids += [blob.id]
      Atlas.persister.save(resource: self)
      @files = nil # invalidate cache so subsequent .files / .mets_blob reflect the new member
      blob.write_preservation_envelope!
      write_preservation_envelope!
      blob
    end

    def write_tmp_mets_xml(raw_xml)
      xml_path = Rails.root.join('tmp', "#{Time.now.to_f.to_s.gsub!('.', '-')}-mets.xml").to_s
      File.write(xml_path, raw_xml)
      xml_path
    end
end
