# frozen_string_literal: true

require 'rails_helper'

describe TextNormalizer do
  describe '.normalize' do
    it 'returns an empty string for nil' do
      expect(described_class.normalize(nil)).to eq('')
    end

    it 'collapses runs of horizontal whitespace to a single space' do
      expect(described_class.normalize("foo \t   bar")).to eq('foo bar')
    end

    it 'collapses NBSP and other Unicode whitespace' do
      expect(described_class.normalize('foo   bar')).to eq('foo bar')
    end

    it 'turns newlines into spaces (atomic field)' do
      expect(described_class.normalize("first\nsecond")).to eq('first second')
    end

    it 'replaces curly quotes with straight quotes' do
      expect(described_class.normalize('It’s a “thing”'.dup.encode('UTF-8'))).to eq(%q(It's a "thing"))
    end

    it 'replaces em/en/figure dashes with ASCII hyphens' do
      expect(described_class.normalize('em—en–fig‒')).to eq('em-en-fig-')
    end

    it 'replaces the swung dash with ASCII tilde' do
      expect(described_class.normalize('a⁓b')).to eq('a~b')
    end

    it 'replaces ellipsis with three dots' do
      expect(described_class.normalize('wait…')).to eq('wait...')
    end

    it 'strips zero-width characters' do
      expect(described_class.normalize('vis​ible')).to eq('visible')
    end

    it 'strips C0 control characters but preserves the value otherwise' do
      expect(described_class.normalize("ok\x07now")).to eq('oknow')
    end

    it 'scrubs invalid UTF-8 sequences without raising' do
      bad = (+"hello\xC2world").force_encoding('ASCII-8BIT')
      expect(described_class.normalize(bad)).to eq('helloworld')
    end

    it 'strips leading and trailing whitespace' do
      expect(described_class.normalize("  hi  \t ")).to eq('hi')
    end
  end

  describe '.normalize_paragraphs' do
    it 'preserves a single blank-line paragraph break' do
      expect(described_class.normalize_paragraphs("first\n\nsecond")).to eq("first\n\nsecond")
    end

    it 'caps runs of newlines at exactly one paragraph break' do
      expect(described_class.normalize_paragraphs("first\n\n\n\n\n\nsecond"))
        .to eq("first\n\nsecond")
    end

    it 'treats a single newline as a soft wrap (collapsed to space)' do
      expect(described_class.normalize_paragraphs("wrap\nped"))
        .to eq('wrap ped')
    end

    it 'collapses horizontal whitespace within paragraphs' do
      expect(described_class.normalize_paragraphs("a   b\n\nc \t d"))
        .to eq("a b\n\nc d")
    end

    it 'strips lines of pure whitespace inside paragraph runs' do
      expect(described_class.normalize_paragraphs("a\n   \n   \nb"))
        .to eq("a\n\nb")
    end

    it 'strips leading/trailing whitespace from the whole field' do
      expect(described_class.normalize_paragraphs("\n\n  hi  \n\n"))
        .to eq('hi')
    end

    it 'normalises curly quotes inside paragraphs' do
      expect(described_class.normalize_paragraphs("She said “hi”.\n\nThen left."))
        .to eq(%(She said "hi".\n\nThen left.))
    end
  end
end
