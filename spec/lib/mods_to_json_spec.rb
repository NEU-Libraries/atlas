# frozen_string_literal: true

require 'rails_helper'

describe MODSToJson do
  let(:converter) do
    Class.new do
      include MODSToJson
    end.new
  end

  def mods_with(inner)
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <mods:mods xmlns:mods="http://www.loc.gov/mods/v3" version="3.7">
        <mods:titleInfo><mods:title>x</mods:title></mods:titleInfo>
        #{inner}
      </mods:mods>
    XML
  end

  describe '#convert_xml_to_json' do
    it 'joins multiple <accessCondition> elements with a paragraph break' do
      xml = mods_with(<<~MODS)
        <mods:accessCondition type="use and reproduction">First condition. (http://example.com/a)</mods:accessCondition>
        <mods:accessCondition type="use and reproduction">Second condition.</mods:accessCondition>
      MODS

      result = converter.convert_xml_to_json(xml)
      expect(result['access_condition']).to eq(
        "First condition. (http://example.com/a)\n\nSecond condition."
      )
    end

    it 'joins multiple <abstract> elements with a paragraph break' do
      xml = mods_with(<<~MODS)
        <mods:abstract>First abstract.</mods:abstract>
        <mods:abstract>Second abstract.</mods:abstract>
      MODS

      result = converter.convert_xml_to_json(xml)
      expect(result['abstract']).to eq("First abstract.\n\nSecond abstract.")
    end

    it 'preserves a blank-line paragraph break inside a single <abstract>' do
      xml = mods_with(<<~MODS)
        <mods:abstract>First paragraph.

        Second paragraph.</mods:abstract>
      MODS

      result = converter.convert_xml_to_json(xml)
      expect(result['abstract']).to eq("First paragraph.\n\nSecond paragraph.")
    end

    it 'returns an empty string when the field is absent' do
      result = converter.convert_xml_to_json(mods_with(''))
      expect(result['access_condition']).to eq('')
      expect(result['abstract']).to eq('')
    end
  end
end
