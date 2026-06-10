# frozen_string_literal: true

# Work-level METS: a physical structMap recording page order — the
# preservation record that FileSet#position denormalizes at runtime.
# Sibling of METSBuilder (which emits the FileSet-level TYPE="logical"
# map over Blobs); reuses its header/root helpers via include.
module METSWorkBuilder
  include METSBuilder

  def mets_for_work(work, file_sets:, created_at: nil)
    builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
      xml.mets(mets_root_attrs(objid: "urn:neu-drs:#{work.noid}", label: 'Work')) do
        build_mets_hdr(xml, created_at.presence || Time.now.utc.iso8601)
        build_physical_struct_map(xml, file_sets)
      end
    end
    builder.to_xml
  end

  private

    # One div TYPE="page" per page-bearing FileSet. mptr (not fptr): the
    # page's file detail lives in that FileSet's own METS object — the
    # standard multi-document METS linking device — so no Work-level
    # fileSec duplicates Blob entries. ORDER is emitted only when a
    # position is present; document order always matches the runtime
    # listing's total order either way, so page order survives in plain
    # text even for legacy/unordered Works.
    def build_physical_struct_map(xml, file_sets)
      xml.structMap('TYPE' => 'physical') do
        xml.div('TYPE' => 'work') do
          file_sets.each { |fs| build_page_div(xml, fs) }
        end
      end
    end

    def build_page_div(xml, file_set)
      attrs = { 'TYPE' => 'page' }
      attrs['ORDER'] = file_set.position.to_s if file_set.position.present?
      attrs['LABEL'] = file_set.type if file_set.type.present?
      xml.div(attrs) do
        xml.mptr('LOCTYPE' => 'URL', 'xlink:href' => "urn:neu-drs:#{file_set.noid}")
      end
    end
end
