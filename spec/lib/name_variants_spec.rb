# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NameVariants do
  describe '.for_given' do
    it 'expands a formal name to its diminutives' do
      expect(described_class.for_given('Timothy')).to contain_exactly('Tim', 'Timmy')
    end

    # The reverse direction is the one a record typed by a photo desk needs:
    # the keyword says "Tim" and the reader searches "Timothy".
    it 'expands a diminutive to every formal name it belongs to, and their siblings' do
      expect(described_class.for_given('Tim')).to contain_exactly('Timon', 'Timothy', 'Timmy')
    end

    it 'ignores case' do
      expect(described_class.for_given('NICK')).to include('Nicholas')
    end

    it 'folds accents, so an unaccented spelling finds the accented row' do
      expect(described_class.for_given('Concepcion')).to eq(['Connie'])
    end

    it 'returns nothing for a word that is not in the table' do
      expect(described_class.for_given('Northeastern')).to eq([])
    end
  end

  describe '.split' do
    it 'reads the comma form neu-mods composes' do
      expect(described_class.split('Smith, Timothy J.')).to eq(%w[Timothy Smith])
    end

    it 'reads direct order' do
      expect(described_class.split('Nick Myers')).to eq(%w[Nick Myers])
    end

    it 'drops the middle of a direct-order name' do
      expect(described_class.split('Timothy J. Smith')).to eq(%w[Timothy Smith])
    end

    it 'strips the dates an LC heading appends' do
      aggregate_failures do
        expect(described_class.split('Stone, Alyssa, 1990-')).to eq(%w[Alyssa Stone])
        expect(described_class.split('Kennedy, John F., 1917-1963')).to eq(%w[John Kennedy])
      end
    end

    it 'finds no family name in a single word' do
      expect(described_class.split('Boston')).to eq(['Boston', nil])
    end
  end

  describe '.full_names' do
    it 'writes each variant in direct order with the family name' do
      expect(described_class.full_names('Myers, Nick'))
        .to contain_exactly('Nicholas Myers', 'Coll Myers', 'Nic Myers', 'Nicky Myers')
    end

    it 'writes nothing without a family name' do
      expect(described_class.full_names('Tim')).to eq([])
    end

    it 'writes nothing when the given name is not in the table' do
      expect(described_class.full_names('Northeastern University. Libraries')).to eq([])
    end
  end

  describe '.name_shaped?' do
    it 'accepts two or three capitalized words' do
      aggregate_failures do
        expect(described_class.name_shaped?('Nick Myers')).to be(true)
        expect(described_class.name_shaped?('Myers, Nick')).to be(true)
        expect(described_class.name_shaped?('Timothy J. Smith')).to be(true)
      end
    end

    it 'rejects a single word, a long phrase, and a lowercase word' do
      aggregate_failures do
        expect(described_class.name_shaped?('Boston')).to be(false)
        expect(described_class.name_shaped?('Co-Founder and CEO of Phoenix Tailings')).to be(false)
        expect(described_class.name_shaped?('NU entrepreneurs')).to be(false)
      end
    end
  end
end
