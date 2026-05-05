# frozen_string_literal: true

require 'rails_helper'

describe DecoratorHelper do
  let(:helper) do
    Class.new do
      include DecoratorHelper
    end.new
  end

  describe '#linkify' do
    it 'returns an empty html_safe string for nil' do
      result = helper.linkify(nil)
      expect(result).to eq('')
      expect(result).to be_html_safe
    end

    it 'returns an empty html_safe string for blank input' do
      expect(helper.linkify('   ')).to eq('')
    end

    it 'escapes plain text containing no URLs' do
      expect(helper.linkify('Hello & welcome'))
        .to eq('Hello &amp; welcome')
    end

    it 'links a bare http URL' do
      expect(helper.linkify('http://hdl.handle.net/2047/D20254217')).to eq(
        '<a href="http://hdl.handle.net/2047/D20254217" rel="nofollow noopener" ' \
        'target="_blank">http://hdl.handle.net/2047/D20254217</a>'
      )
    end

    it 'links an https URL' do
      expect(helper.linkify('see https://example.com/path here')).to eq(
        'see <a href="https://example.com/path" rel="nofollow noopener" ' \
        'target="_blank">https://example.com/path</a> here'
      )
    end

    it 'leaves trailing punctuation outside the link (parenthesised URL)' do
      input = 'rights (http://rightsstatements.org/page/InC/1.0/?language=en)'
      expect(helper.linkify(input)).to eq(
        'rights (<a href="http://rightsstatements.org/page/InC/1.0/?language=en" ' \
        'rel="nofollow noopener" target="_blank">' \
        'http://rightsstatements.org/page/InC/1.0/?language=en</a>)'
      )
    end

    it 'leaves trailing punctuation outside the link (sentence period)' do
      expect(helper.linkify('See http://example.com/foo.'))
        .to include('http://example.com/foo</a>.')
    end

    it 'does not link a URL whose host has no dot' do
      expect(helper.linkify('go to http://localhost/foo'))
        .to eq('go to http://localhost/foo')
    end

    it 'does not link a malformed URL (parse failure)' do
      expect(helper.linkify('weird http://[bad/'))
        .to eq('weird http://[bad/')
    end

    it 'does not link non-http(s) schemes' do
      expect(helper.linkify('javascript:alert(1)'))
        .to eq('javascript:alert(1)')
    end

    it 'preserves <sup> and <sub> from curator input' do
      expect(helper.linkify('H<sub>2</sub>O and E=mc<sup>2</sup>'))
        .to eq('H<sub>2</sub>O and E=mc<sup>2</sup>')
    end

    it 'strips disallowed inline tags' do
      expect(helper.linkify('<b>important</b> and <i>note</i>'))
        .to eq('important and note')
    end

    it 'strips curator-typed <a> tags entirely (link-text remains as plain text)' do
      input = 'See <a href="https://example.com">click here</a> for info.'
      expect(helper.linkify(input)).to eq('See click here for info.')
    end

    it 'strips <script> contents along with the tag' do
      input = 'Hello <script>alert(1)</script> world'
      expect(helper.linkify(input)).to eq('Hello  world')
    end

    it 'strips <style> contents along with the tag' do
      input = 'Pre <style>body{}</style> post'
      expect(helper.linkify(input)).to eq('Pre  post')
    end

    it 'turns a blank-line paragraph break into <br><br>' do
      expect(helper.linkify("first\n\nsecond")).to eq('first<br><br>second')
    end

    it 'caps multiple consecutive newlines at exactly one <br><br>' do
      expect(helper.linkify("first\n\n\n\n\nsecond")).to eq('first<br><br>second')
    end

    it 'treats lone newlines as a single space (soft wrap)' do
      expect(helper.linkify("wrap\nped")).to eq('wrap ped')
    end

    it 'strips curator-typed <br> tags (br is not in the whitelist)' do
      expect(helper.linkify('a<br><br><br><br>b'))
        .to eq('ab')
    end

    it 'returns an html_safe string' do
      expect(helper.linkify('plain text')).to be_html_safe
    end

    it 'links the parenthesised rightsstatements URL alongside surrounding rights text' do
      input = 'In Copyright: blah (http://rightsstatements.org/page/InC/1.0/?language=en)'
      result = helper.linkify(input)
      expect(result).to start_with('In Copyright: blah (<a href=')
      expect(result).to end_with('?language=en</a>)')
    end

    it 'handles a paragraph with both <sub> and an autolinked URL' do
      input = "H<sub>2</sub>O reference\n\nSee https://example.com/x for details."
      expect(helper.linkify(input)).to eq(
        'H<sub>2</sub>O reference<br><br>See ' \
        '<a href="https://example.com/x" rel="nofollow noopener" target="_blank">' \
        'https://example.com/x</a> for details.'
      )
    end
  end
end
