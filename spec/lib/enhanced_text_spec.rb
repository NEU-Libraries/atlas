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

  describe '.render' do
    it 'keeps the two tags as markup' do
      expect(described_class.render('Bi<sub>2</sub>O and E=mc<sup>2</sup>'))
        .to eq('Bi<sub>2</sub>O and E=mc<sup>2</sup>')
    end

    it 'case-folds an upper-case tag' do
      expect(described_class.render('<SUB>2</SUB>')).to eq('<sub>2</sub>')
    end

    # The defect .render exists for. An HTML parser treats a bare "<" before a
    # letter as opening an element and discards everything to the next ">", so
    # this value used to render as "Ti 2O" -- the span gone AND the subscript
    # with it. .strip never had the bug; now the display path matches it.
    it 'never lets a literal less-than open an element' do
      expect(described_class.render('Ti <Tc in Bi<sub>2</sub>O'))
        .to eq('Ti &lt;Tc in Bi<sub>2</sub>O')
      expect(described_class.render('Temperature <Kelvin')).to eq('Temperature &lt;Kelvin')
      expect(described_class.render('a < b')).to eq('a &lt; b')
    end

    it 'escapes the three characters an HTML text node must escape' do
      expect(described_class.render('Steel & Iron <> here')).to eq('Steel &amp; Iron &lt;&gt; here')
    end

    it 'leaves the quote characters alone -- the value is text, never an attribute' do
      expect(described_class.render(%q(What's "New"))).to eq(%q(What's "New"))
    end

    it 'refuses to revive a tag that carries anything at all' do
      expect(described_class.render('<sub onmouseover="x()">2'))
        .to eq('&lt;sub onmouseover="x()"&gt;2')
      expect(described_class.render('<script>alert(1)</script>'))
        .to eq('&lt;script&gt;alert(1)&lt;/script&gt;')
    end

    it 'does not double-revive an already-escaped tag' do
      expect(described_class.render('already &lt;sub&gt; escaped'))
        .to eq('already &amp;lt;sub&amp;gt; escaped')
    end

    it 'answers an empty string for nil' do
      expect(described_class.render(nil)).to eq('')
    end
  end

  describe 'round trip' do
    it 'render and strip read the same allowlist, so display and match agree' do
      value = 'Bi<sub>2</sub>Sr<sub>2</sub>O and Ti <Tc'

      expect(described_class.render(value)).to eq('Bi<sub>2</sub>Sr<sub>2</sub>O and Ti &lt;Tc')
      expect(described_class.strip(value)).to eq('Bi2Sr2O and Ti <Tc')
    end
  end
end
