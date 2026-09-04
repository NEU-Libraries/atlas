# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Metadata::MODS do
  # The attribute set is derived from the gem's registry rather than restated,
  # so "declared but never projected" cannot happen again. What still can is a
  # projected field with no display row -- the attribute fills, and the reader
  # sees nothing. These are the guards for that, and for the derivation itself.
  describe 'projection coverage' do
    let(:declared) { described_class.attr_json_registry.attribute_names }
    let(:projected) { NEU::MODS::Document.parse(file_fixture('mods-coverage.xml').read).to_h.keys }

    it 'declares exactly the fields the gem projects' do
      expect(declared).to match_array(NEU::MODS::FIELDS.keys)
    end

    # A coverage fixture that omits an element makes every spec here pass for
    # the wrong reason: the field looks projected because nothing exercised it.
    it 'exercises every declared field from the coverage fixture' do
      expect(declared - projected).to be_empty
    end

    it 'stores every projected key, so none is silently dropped on assign' do
      record = described_class.new
      record.assign_attributes(NEU::MODS::Document.parse(file_fixture('mods-coverage.xml').read).to_h)
      expect(record.json_attributes.keys.map(&:to_sym)).to match_array(projected)
    end
  end

  describe 'the shapes the display and the indexers depend on' do
    subject(:record) do
      described_class.new.tap do |m|
        m.assign_attributes(NEU::MODS::Document.parse(file_fixture('mods-coverage.xml').read).to_h)
      end
    end

    it 'keeps a repeatable element as an array, not its first value' do
      expect(record.resource_type).to eq(['text', 'still image'])
    end

    it 'stores a date as a datetime beside the precision that formats it' do
      aggregate_failures do
        expect(record.copyright_date).to be_a(ActiveSupport::TimeWithZone)
        expect(record.copyright_date_precision).to eq('year')
        expect(record.date_issued_precision).to eq('day')
      end
    end

    it 'stores the structured fields as models, not as bare hashes' do
      aggregate_failures do
        expect(record.notes.first).to be_a(Metadata::Fields::Note)
        expect(record.notes.first.type).to eq('statement of responsibility')
        expect(record.location.first).to be_a(Metadata::Fields::Location)
        expect(record.location.first.physical_location).to eq('Snell Library')
        expect(record.related_items.first).to be_a(Metadata::Fields::RelatedItem)
        expect(record.related_items.first.type).to eq('otherFormat')
      end
    end

    it 'keeps a restriction and a licence apart' do
      aggregate_failures do
        expect(record.restriction_on_access).to eq('Northeastern University only.')
        expect(record.use_and_reproduction).to eq('CC BY 4.0')
      end
    end
  end

  # Nothing fails when a projected field has no display row: the attribute
  # fills, and the row silently does not render. That is how twelve of the
  # thirty-four fields ended up invisible, so the omission has to be explicit.
  describe 'display coverage' do
    let(:displayed) { WorkDecorator::DISPLAY.pluck(:field) }

    it 'gives every projected field a display row or an explicit omission' do
      expect(NEU::MODS::FIELDS.keys - displayed - WorkDecorator::NOT_DISPLAYED).to be_empty
    end

    it 'displays nothing the gem does not project' do
      expect(displayed - NEU::MODS::FIELDS.keys).to be_empty
    end

    it 'lists nothing as not-displayed that also has a row' do
      expect(WorkDecorator::NOT_DISPLAYED & displayed).to be_empty
    end
  end
end
