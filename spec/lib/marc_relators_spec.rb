# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MarcRelators do
  describe '.label' do
    it 'translates a MARC relator code into the label a reader sees' do
      aggregate_failures do
        expect(described_class.label('aut')).to eq('Author')
        expect(described_class.label('pht')).to eq('Photographer')
      end
    end

    it 'folds case, because a record is not obliged to lowercase its code' do
      expect(described_class.label('AUT')).to eq('Author')
    end

    it 'leaves a text term alone' do
      expect(described_class.label('Creator')).to eq('Creator')
    end

    # Losing an unrecognised value would be worse than showing it: the record
    # still said something, and nothing downstream could recover it.
    it 'returns an unrecognised role unchanged' do
      expect(described_class.label('Wrangler')).to eq('Wrangler')
    end

    it 'returns nil for an absent role, so a caller can apply its own default' do
      aggregate_failures do
        expect(described_class.label(nil)).to be_nil
        expect(described_class.label('  ')).to be_nil
      end
    end
  end

  # An unlisted code fell through to itself and #names used the result as a row
  # heading, so a typo'd "zzz" became a label -- the outcome suppressing
  # displayLabel exists to prevent. The shape is the only thing separating an
  # unlisted CODE from a free-text roleTerm, because neu-mods projects the text
  # term in preference to the code and does not say which it gave.
  describe '.unknown_code?' do
    it 'recognises a code-shaped role the table does not hold' do
      aggregate_failures do
        expect(described_class.unknown_code?('zzz')).to be true
        expect(described_class.unknown_code?('ZZZ')).to be true
      end
    end

    it 'rejects a code the table does hold' do
      aggregate_failures do
        expect(described_class.unknown_code?('aut')).to be false
        expect(described_class.unknown_code?('pht')).to be false
      end
    end

    # A cataloguer writes these into a text roleTerm and they have to survive
    # as themselves.
    it 'rejects a free-text role term, whatever the table knows of it' do
      aggregate_failures do
        expect(described_class.unknown_code?('Photographer')).to be false
        expect(described_class.unknown_code?('Wrangler')).to be false
        expect(described_class.unknown_code?('Creator')).to be false
      end
    end

    it 'rejects an absent role, which is not the same as an unrecognised one' do
      aggregate_failures do
        expect(described_class.unknown_code?(nil)).to be false
        expect(described_class.unknown_code?('  ')).to be false
      end
    end

    # .creator? reads the same value through .label, and an unlisted code is
    # not a creator either way -- so the classification is unchanged.
    it 'leaves .label and .creator? alone' do
      aggregate_failures do
        expect(described_class.label('zzz')).to eq('zzz')
        expect(described_class.creator?('zzz')).to be false
      end
    end
  end

  # Matching the literal string "creator" excluded `aut` and `Author`, which
  # are the same claim written differently, so a record using either was
  # missing from the creator facet and harvested as dc:contributor.
  describe '.creator?' do
    it 'accepts the term and the code for both synonyms' do
      aggregate_failures do
        expect(described_class.creator?('Creator')).to be true
        expect(described_class.creator?('cre')).to be true
        expect(described_class.creator?('Author')).to be true
        expect(described_class.creator?('aut')).to be true
      end
    end

    it 'folds case' do
      expect(described_class.creator?('CREATOR')).to be true
    end

    # MODS makes mods:role optional, the display labels a role-less name
    # Creator, and mods_display treats an empty role the same way.
    it 'counts an absent role as a creator, matching the display' do
      aggregate_failures do
        expect(described_class.creator?(nil)).to be true
        expect(described_class.creator?('')).to be true
      end
    end

    it 'rejects a role that names someone else, so attribution stays right' do
      aggregate_failures do
        expect(described_class.creator?('Contributor')).to be false
        expect(described_class.creator?('ths')).to be false
        expect(described_class.creator?('edt')).to be false
      end
    end
  end
end
