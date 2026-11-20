# frozen_string_literal: true

# Work-level METS: the preservation record of the Work's file order, and its
# link to the MODS. See docs/resource-graph.md for the page rule.
module METSWorkBuilder
  include METSBuilder

  DMD_ID = 'dmd-mods'

  # Only a Work made entirely of images is a sequence of pages. A PDF of 300
  # pages is one FileSet, so calling each FileSet a page would misdescribe it.
  def self.paged?(file_sets)
    file_sets.any? && file_sets.all? { |fs| fs.type == Classification.image.name }
  end

  def mets_for_work(work, file_sets:, created_at: nil, last_modified: nil)
    now = Time.now.utc.iso8601
    mods_blob = work.mods_blob
    builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
      xml.mets(mets_root_attrs(objid: "urn:neu-drs:#{work.noid}", label: 'Work')) do
        build_mets_hdr(xml, created_at.presence || now, last_modified.presence || now)
        build_dmd_sec(xml, mods_blob) if mods_blob&.noid.present?
        build_work_struct_map(xml, file_sets, dmd: mods_blob&.noid.present?)
      end
    end
    builder.to_xml
  end

  private

    def build_dmd_sec(xml, mods_blob)
      xml.dmdSec('ID' => DMD_ID) do
        xml.mdRef('LOCTYPE' => 'URN', 'MDTYPE' => 'MODS', 'MIMETYPE' => 'application/xml',
                  'xlink:href' => "urn:neu-drs:#{mods_blob.noid}")
      end
    end

    # mptr, not fptr: each FileSet's own METS holds its file detail, so the
    # Work carries no fileSec. ORDER only when a position is present;
    # document order matches works#file_sets either way.
    def build_work_struct_map(xml, file_sets, dmd:)
      paged = METSWorkBuilder.paged?(file_sets)
      root  = { 'TYPE' => 'work' }
      root['DMDID'] = DMD_ID if dmd

      xml.structMap('TYPE' => paged ? 'physical' : 'logical') do
        xml.div(root) do
          file_sets.each { |fs| build_member_div(xml, fs, paged ? 'page' : 'file') }
        end
      end
    end

    def build_member_div(xml, file_set, type)
      attrs = { 'TYPE' => type }
      attrs['ORDER'] = file_set.position.to_s if file_set.position.present?
      xml.div(attrs) do
        xml.mptr('LOCTYPE' => 'URN', 'xlink:href' => "urn:neu-drs:#{file_set.noid}")
      end
    end
end
