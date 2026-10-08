# frozen_string_literal: true

# Checks a Simple Darwin Core upload and projects it into the JSON access copy.
# See docs/metadata-records.md.
#
# Atlas checks shape only. Validation against tdwg_dwc_simple.xsd lives in
# Cerberus, so a caller that skips Cerberus can store a record the schema would
# refuse, but never one this projection cannot read.
class DarwinCoreDocument
  RECORD_SET_NS = 'http://rs.tdwg.org/dwc/xsd/simpledarwincore/'

  # The namespaces whose terms the access copy carries. A term from any other
  # namespace stays in the preserved XML and is left out of the JSON.
  TERM_NAMESPACES = %w[
    http://rs.tdwg.org/dwc/terms/
    http://purl.org/dc/elements/1.1/
    http://purl.org/dc/terms/
  ].freeze

  def self.parse(raw_xml)
    new(raw_xml)
  end

  def initialize(raw_xml)
    @document = parse_strict(raw_xml)
    @record   = single_record
  end

  # Keyed by the term's own name (`catalogNumber`, never `catalog_number`),
  # because Cerberus labels a term by that name. Blank terms are dropped.
  def to_h
    term_elements.each_with_object({}) do |element, terms|
      value = element.text.strip
      next if value.empty?

      # Simple Darwin Core allows each term once. Keeping only the last would
      # drop data from the access copy without anyone noticing.
      if terms.key?(element.name)
        raise Exceptions::DarwinCoreError.new(:duplicate_term, "the term #{element.name} appears more than once")
      end

      terms[element.name] = value
    end
  end

  private

    def parse_strict(raw_xml)
      Nokogiri::XML(raw_xml.to_s, &:strict)
    rescue Nokogiri::XML::SyntaxError => e
      raise Exceptions::DarwinCoreError.new(:malformed_xml, "the document is not well-formed XML: #{e.message}")
    end

    def single_record
      root = @document.root
      unless record_set_element?(root, 'SimpleDarwinRecordSet')
        raise Exceptions::DarwinCoreError.new(:invalid_root, 'the root element must be dwr:SimpleDarwinRecordSet')
      end

      records = root.element_children.select { |e| record_set_element?(e, 'SimpleDarwinRecord') }
      return records.first if records.one?

      raise Exceptions::DarwinCoreError.new(:record_count,
                                            "a Work holds one dwr:SimpleDarwinRecord; found #{records.size}")
    end

    def record_set_element?(node, name)
      node.present? && node.name == name && node.namespace&.href == RECORD_SET_NS
    end

    def term_elements
      @record.element_children.select { |e| TERM_NAMESPACES.include?(e.namespace&.href) }
    end
end
