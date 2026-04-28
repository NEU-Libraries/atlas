# frozen_string_literal: true

module METSBuilder
  METS_NS  = 'http://www.loc.gov/METS/'
  XLINK_NS = 'http://www.w3.org/1999/xlink'
  DRS_NS   = 'https://repository.neu.edu/spec/v1'

  def mets_template
    build_mets(blobs: [], created_at: Time.now.utc.iso8601,
               objid: mets_objid_for_template, label: mets_label_for_template)
  end

  def mets_for(file_set, created_at: nil, blobs: nil)
    build_mets(
      blobs: blobs || file_set.content_files,
      created_at: created_at.presence || Time.now.utc.iso8601,
      objid: file_set.noid.present? ? "urn:neu-drs:#{file_set.noid}" : '',
      label: file_set.type.presence || 'FileSet'
    )
  end

  private

    def build_mets(blobs:, created_at:, objid:, label:)
      builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
        xml.mets(mets_root_attrs(objid: objid, label: label)) do
          build_mets_hdr(xml, created_at)
          build_file_sec(xml, blobs)
          build_struct_map(xml, blobs)
        end
      end
      builder.to_xml
    end

    def mets_root_attrs(objid:, label:)
      {
        'xmlns' => METS_NS,
        'xmlns:xlink' => XLINK_NS,
        'xmlns:drs' => DRS_NS,
        'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance',
        'xsi:schemaLocation' => "#{METS_NS} http://www.loc.gov/standards/mets/mets.xsd",
        'OBJID' => objid,
        'LABEL' => label
      }
    end

    def build_mets_hdr(xml, created_at)
      xml.metsHdr('CREATEDATE' => created_at) do
        xml.agent('ROLE' => 'CREATOR', 'TYPE' => 'OTHER') do
          xml.name 'Atlas'
        end
      end
    end

    def build_file_sec(xml, blobs)
      xml.fileSec do
        xml.fileGrp do
          blobs.each { |blob| build_file_entry(xml, blob) }
        end
      end
    end

    def build_file_entry(xml, blob)
      attrs = file_attrs_for(blob)
      xml.send(:file, attrs) do
        next if blob.latest_revision.blank?

        xml.FLocat('LOCTYPE' => 'URL', 'xlink:href' => blob.latest_revision.to_s)
      end
    end

    def file_attrs_for(blob)
      attrs = { 'ID' => "f-#{blob.noid}" }
      attrs['MIMETYPE'] = blob.mime_type if blob.mime_type.present?
      attrs['SIZE']     = blob.size.to_s if blob.size.present?
      attrs['USE']      = blob.use       if blob.respond_to?(:use) && blob.use.present?
      attrs
    end

    def build_struct_map(xml, blobs)
      xml.structMap('TYPE' => 'logical') do
        xml.div('TYPE' => 'fileSet') do
          blobs.each { |blob| xml.fptr('FILEID' => "f-#{blob.noid}") }
        end
      end
    end

    def mets_objid_for_template
      respond_to?(:noid) && noid.present? ? "urn:neu-drs:#{noid}" : ''
    end

    def mets_label_for_template
      respond_to?(:type) && type.present? ? type : 'FileSet'
    end
end
