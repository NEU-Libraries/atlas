# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EnhancedText do
  describe '.strip' do
    it 'removes the tags and keeps the text, so a formula reads as one token' do
      title = 'Origin of the high-energy kink in the superconductor ' \
              'Bi<sub>2</sub>Sr<sub>2</sub>CaCu<sub>2</sub>O<sub>8</sub>'

      expect(described_class.strip(title))
        .to eq('Origin of the high-energy kink in the superconductor Bi2Sr2CaCu2O8')
    end

    it 'removes a superscript too' do
      expect(described_class.strip('E=mc<sup>2</sup>')).to eq('E=mc2')
    end

    it 'tolerates attributes and mixed case, which the display sanitiser drops' do
      expect(described_class.strip('H<SUB class="x">2</SUB>O')).to eq('H2O')
    end

    it 'leaves a title that carries no markup untouched' do
      expect(described_class.strip('Campus Life: A Photographic Record'))
        .to eq('Campus Life: A Photographic Record')
    end

    it 'leaves a literal angle bracket alone -- it is not a general HTML strip' do
      expect(described_class.strip('Resistivity at Ti < Tc')).to eq('Resistivity at Ti < Tc')
      expect(described_class.strip('a <b>bold</b> claim')).to eq('a <b>bold</b> claim')
    end

    it 'answers an empty string for nil' do
      expect(described_class.strip(nil)).to eq('')
    end
  end

  describe 'TAGS' do
    it 'is the allowlist the display sanitiser renders, so the two halves agree' do
      expect(DecoratorHelper::ENHANCED_TEXT_SANITIZE_CONFIG[:elements]).to be(described_class::TAGS)
    end
  end
end
