# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DarwinCoreDocument do
  def fixture(name)
    Rails.root.join('spec/fixtures/files', name).read
  end

  def record_set(body)
    <<~XML
      <dwr:SimpleDarwinRecordSet xmlns:dwr="http://rs.tdwg.org/dwc/xsd/simpledarwincore/"
          xmlns:dwc="http://rs.tdwg.org/dwc/terms/" xmlns:dcterms="http://purl.org/dc/terms/"
          xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:ex="http://example.org/">
        #{body}
      </dwr:SimpleDarwinRecordSet>
    XML
  end

  def error_code(xml)
    described_class.parse(xml).to_h
    nil
  rescue Exceptions::DarwinCoreError => e
    e.code
  end

  describe '#to_h' do
    subject(:terms) { described_class.parse(fixture('dwc.xml')).to_h }

    it 'keys each term by its own name, across the dwc, dc and dcterms namespaces' do
      expect(terms).to include('catalogNumber'   => 'MVZ:Mamm:14523',
                               'scientificName'  => 'Perognathus inornatus inornatus',
                               'decimalLatitude' => '35.45038',
                               'type'            => 'PhysicalObject',
                               'modified'        => '2009-02-12T12:43:31')
    end

    it 'leaves out blank terms and terms in other namespaces' do
      xml = record_set(<<~BODY)
        <dwr:SimpleDarwinRecord>
          <dwc:catalogNumber>S27880</dwc:catalogNumber>
          <dwc:sex>  </dwc:sex>
          <ex:note>kept on disk only</ex:note>
        </dwr:SimpleDarwinRecord>
      BODY
      expect(described_class.parse(xml).to_h).to eq('catalogNumber' => 'S27880')
    end
  end

  describe 'the shape rules' do
    it 'refuses the TDWG guide example as published, which is not well-formed' do
      expect(error_code(fixture('dwc-tdwg-example-broken.xml'))).to eq(:malformed_xml)
    end

    it 'refuses a root other than dwr:SimpleDarwinRecordSet' do
      expect(error_code(fixture('work-mods.xml'))).to eq(:invalid_root)
    end

    it 'refuses a SimpleDarwinRecordSet element outside the dwr namespace' do
      expect(error_code('<SimpleDarwinRecordSet><SimpleDarwinRecord/></SimpleDarwinRecordSet>')).to eq(:invalid_root)
    end

    it 'refuses an empty document' do
      expect(error_code('')).to be_in(%i[malformed_xml invalid_root])
    end

    it 'refuses more than one dwr:SimpleDarwinRecord' do
      expect(error_code(fixture('dwc-two-records.xml'))).to eq(:record_count)
    end

    it 'refuses a set with no dwr:SimpleDarwinRecord' do
      expect(error_code(record_set(''))).to eq(:record_count)
    end

    it 'refuses a term that appears twice, even across namespaces' do
      xml = record_set(<<~BODY)
        <dwr:SimpleDarwinRecord>
          <dc:type>PhysicalObject</dc:type>
          <dcterms:type>PhysicalObject</dcterms:type>
        </dwr:SimpleDarwinRecord>
      BODY
      expect(error_code(xml)).to eq(:duplicate_term)
    end
  end
end
