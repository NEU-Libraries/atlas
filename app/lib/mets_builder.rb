# frozen_string_literal: true

# FileSet-level METS: a fileSec over the FileSet's content Blobs and the
# logical structMap the schema requires. See docs/resource-graph.md.
module METSBuilder
  METS_NS  = 'http://www.loc.gov/METS/'
  XLINK_NS = 'http://www.w3.org/1999/xlink'
  DRS_NS   = 'https://repository.neu.edu/spec/v1'

  # The OCFL digest names Atlas records, mapped to METS's CHECKSUMTYPE
  # vocabulary. A digest outside it is left off rather than mislabelled.
  CHECKSUM_TYPES = {
    'md5' => 'MD5', 'sha1' => 'SHA-1', 'sha256' => 'SHA-256', 'sha512' => 'SHA-512'
  }.freeze

  def mets_template
    now = Time.now.utc.iso8601
    build_mets(blobs: [], created_at: now, last_modified: now,
               objid: mets_objid_for_template, label: mets_label_for_template)
  end

  def mets_for(file_set, created_at: nil, last_modified: nil, blobs: nil)
    now = Time.now.utc.iso8601
    build_mets(
      blobs:         blobs || file_set.content_files,
      created_at:    created_at.presence || now,
      last_modified: last_modified.presence || now,
      objid:         file_set.noid.present? ? "urn:neu-drs:#{file_set.noid}" : '',
      label:         file_set.type.presence || 'FileSet'
    )
  end

  private

    def build_mets(blobs:, created_at:, last_modified:, objid:, label:)
      builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
        xml.mets(mets_root_attrs(objid: objid, label: label)) do
          build_mets_hdr(xml, created_at, last_modified)
          build_file_sec(xml, blobs)
          build_struct_map(xml, blobs)
        end
      end
      builder.to_xml
    end

    def mets_root_attrs(objid:, label:)
      {
        'xmlns'              => METS_NS,
        'xmlns:xlink'        => XLINK_NS,
        'xmlns:drs'          => DRS_NS,
        'xmlns:xsi'          => 'http://www.w3.org/2001/XMLSchema-instance',
        'xsi:schemaLocation' => "#{METS_NS} http://www.loc.gov/standards/mets/mets.xsd",
        'OBJID'              => objid,
        'LABEL'              => label
      }
    end

    def build_mets_hdr(xml, created_at, last_modified)
      xml.metsHdr('CREATEDATE' => created_at, 'LASTMODDATE' => last_modified) do
        xml.agent('ROLE' => 'CREATOR', 'TYPE' => 'OTHER', 'OTHERTYPE' => 'SOFTWARE') do
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

    # The href is the OCFL version id, which names a path under a storage
    # root rather than anything a browser resolves, so it is not a URL.
    def build_file_entry(xml, blob)
      attrs = file_attrs_for(blob)
      xml.send(:file, attrs) do
        next if blob.latest_revision.blank?

        xml.FLocat('LOCTYPE' => 'OTHER', 'OTHERLOCTYPE' => 'OCFL', 'xlink:href' => blob.latest_revision.to_s)
      end
    end

    def file_attrs_for(blob)
      attrs = { 'ID' => "f-#{blob.noid}" }
      attrs['MIMETYPE'] = blob.mime_type if blob.mime_type.present?
      attrs['SIZE']     = blob.size.to_s if blob.size.present?
      attrs.merge!(checksum_attrs(blob.digest))
      attrs['USE'] = blob.use if blob.respond_to?(:use) && blob.use.present?
      attrs
    end

    # Blob#digest is "<algorithm>:<hex>", the form recorded_digest writes.
    def checksum_attrs(digest)
      algorithm, value = digest.to_s.split(':', 2)
      type = CHECKSUM_TYPES[algorithm.to_s.downcase]
      return {} if type.nil? || value.blank?

      { 'CHECKSUM' => value, 'CHECKSUMTYPE' => type }
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
