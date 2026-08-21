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
        .to eq('<p>Hello &amp; welcome</p>')
    end

    it 'links a bare http URL' do
      expect(helper.linkify('http://hdl.handle.net/2047/D20254217')).to eq(
        '<p><a href="http://hdl.handle.net/2047/D20254217" rel="nofollow noopener" ' \
        'target="_blank">http://hdl.handle.net/2047/D20254217</a></p>'
      )
    end

    it 'links an https URL' do
      expect(helper.linkify('see https://example.com/path here')).to eq(
        '<p>see <a href="https://example.com/path" rel="nofollow noopener" ' \
        'target="_blank">https://example.com/path</a> here</p>'
      )
    end

    it 'leaves trailing punctuation outside the link (parenthesised URL)' do
      input = 'rights (http://rightsstatements.org/page/InC/1.0/?language=en)'
      expect(helper.linkify(input)).to eq(
        '<p>rights (<a href="http://rightsstatements.org/page/InC/1.0/?language=en" ' \
        'rel="nofollow noopener" target="_blank">' \
        'http://rightsstatements.org/page/InC/1.0/?language=en</a>)</p>'
      )
    end

    it 'leaves trailing punctuation outside the link (sentence period)' do
      expect(helper.linkify('See http://example.com/foo.'))
        .to include('http://example.com/foo</a>.')
    end

    it 'terminates URL at an unbalanced ) when text runs on without whitespace' do
      input = '(http://rightsstatements.org/page/InC/1.0/?language=en)Copyright restrictions may apply.'
      result = helper.linkify(input)
      expect(result).to include('href="http://rightsstatements.org/page/InC/1.0/?language=en"')
      expect(result).to include('?language=en</a>)Copyright restrictions may apply.')
      expect(result).not_to include('en)Copyright')
    end

    it 'keeps balanced parens inside a URL (Wikipedia-style)' do
      input = 'See https://en.wikipedia.org/wiki/Foo_(disambiguation) here.'
      expect(helper.linkify(input)).to include(
        'href="https://en.wikipedia.org/wiki/Foo_(disambiguation)"'
      )
    end

    it 'splits two URLs separated only by punctuation' do
      input = 'http://a.example.com/x)http://b.example.com/y'
      result = helper.linkify(input)
      expect(result).to include('href="http://a.example.com/x"')
      expect(result).to include('href="http://b.example.com/y"')
    end

    it 'does not link a URL whose host has no dot' do
      expect(helper.linkify('go to http://localhost/foo'))
        .to eq('<p>go to http://localhost/foo</p>')
    end

    it 'does not link a malformed URL (parse failure)' do
      expect(helper.linkify('weird http://[bad/'))
        .to eq('<p>weird http://[bad/</p>')
    end

    it 'does not link non-http(s) schemes' do
      expect(helper.linkify('javascript:alert(1)'))
        .to eq('<p>javascript:alert(1)</p>')
    end

    it 'preserves <sup> and <sub> from curator input' do
      expect(helper.linkify('H<sub>2</sub>O and E=mc<sup>2</sup>'))
        .to eq('<p>H<sub>2</sub>O and E=mc<sup>2</sup></p>')
    end

    it 'strips disallowed inline tags' do
      expect(helper.linkify('<b>important</b> and <i>note</i>'))
        .to eq('<p>important and note</p>')
    end

    it 'strips curator-typed <a> tags entirely (link-text remains as plain text)' do
      input = 'See <a href="https://example.com">click here</a> for info.'
      expect(helper.linkify(input)).to eq('<p>See click here for info.</p>')
    end

    it 'strips <script> contents along with the tag' do
      input = 'Hello <script>alert(1)</script> world'
      expect(helper.linkify(input)).to eq('<p>Hello  world</p>')
    end

    it 'strips <style> contents along with the tag' do
      input = 'Pre <style>body{}</style> post'
      expect(helper.linkify(input)).to eq('<p>Pre  post</p>')
    end

    it 'wraps a single paragraph in <p>' do
      expect(helper.linkify('only one')).to eq('<p>only one</p>')
    end

    it 'wraps each blank-line-delimited paragraph in its own <p>' do
      expect(helper.linkify("first\n\nsecond")).to eq('<p>first</p><p>second</p>')
    end

    it 'collapses runs of blank lines into a single paragraph break' do
      expect(helper.linkify("first\n\n\n\n\nsecond")).to eq('<p>first</p><p>second</p>')
    end

    it 'drops blank paragraphs (whitespace-only between blank lines)' do
      expect(helper.linkify("first\n\n   \n\nsecond")).to eq('<p>first</p><p>second</p>')
    end

    it 'treats lone newlines as a single space (soft wrap)' do
      expect(helper.linkify("wrap\nped")).to eq('<p>wrap ped</p>')
    end

    it 'strips curator-typed <br> tags (br is not in the whitelist)' do
      expect(helper.linkify('a<br><br><br><br>b'))
        .to eq('<p>ab</p>')
    end

    it 'returns an html_safe string' do
      expect(helper.linkify('plain text')).to be_html_safe
    end

    it 'links the parenthesised rightsstatements URL alongside surrounding rights text' do
      input = 'In Copyright: blah (http://rightsstatements.org/page/InC/1.0/?language=en)'
      result = helper.linkify(input)
      expect(result).to start_with('<p>In Copyright: blah (<a href=')
      expect(result).to end_with('?language=en</a>)</p>')
    end

    it 'handles a paragraph with both <sub> and an autolinked URL' do
      input = "H<sub>2</sub>O reference\n\nSee https://example.com/x for details."
      expect(helper.linkify(input)).to eq(
        '<p>H<sub>2</sub>O reference</p><p>See ' \
        '<a href="https://example.com/x" rel="nofollow noopener" target="_blank">' \
        'https://example.com/x</a> for details.</p>'
      )
    end
  end

  describe '#enhanced_text' do
    it 'renders the sub/sup a record escaped into a title text node' do
      result = helper.enhanced_text('Bi<sub>2</sub>Sr<sub>2</sub>CaCu<sub>2</sub>O<sub>8</sub>')

      expect(result).to eq('Bi<sub>2</sub>Sr<sub>2</sub>CaCu<sub>2</sub>O<sub>8</sub>')
      expect(result).to be_html_safe
    end

    it 'adds no paragraph wrapper -- a title is one line, unlike linkify prose' do
      expect(helper.enhanced_text("What's New")).to eq("What's New")
    end

    it 'escapes text that is not part of the allowlist' do
      expect(helper.enhanced_text('Steel & Iron')).to eq('Steel &amp; Iron')
      expect(helper.enhanced_text('Resistivity at Ti < Tc')).to eq('Resistivity at Ti &lt; Tc')
    end

    it 'drops a tag outside the allowlist, keeping its text' do
      expect(helper.enhanced_text('a <b>bold</b> claim')).to eq('a bold claim')
    end

    it 'drops attributes a record put on an allowed tag' do
      expect(helper.enhanced_text('H<sub class="x">2</sub>O')).to eq('H<sub>2</sub>O')
    end

    it 'does not autolink -- a title is a value, not prose' do
      expect(helper.enhanced_text('See http://example.com')).to eq('See http://example.com')
    end

    it 'returns an empty html_safe string for a blank value' do
      result = helper.enhanced_text(nil)
      expect(result).to eq('')
      expect(result).to be_html_safe
    end
  end

  describe '#field' do
    it 'renders a dt/dd pair for a present value' do
      expect(helper.field('Date created', '2017-09-19'))
        .to eq('<dt>Date created</dt><dd>2017-09-19</dd>')
    end

    it 'omits the whole field (label + value) for a nil value' do
      expect(helper.field('Date created', nil)).to eq('')
    end

    it 'omits the whole field for a blank value' do
      expect(helper.field('Use and reproduction', '   ')).to eq('')
    end

    it 'runs the value through linkify when link: true' do
      expect(helper.field('Permanent URL', 'http://hdl.handle.net/2047/D20254217', link: true))
        .to eq(
          '<dt>Permanent URL</dt><dd><p>' \
          '<a href="http://hdl.handle.net/2047/D20254217" rel="nofollow noopener" ' \
          'target="_blank">http://hdl.handle.net/2047/D20254217</a></p></dd>'
        )
    end

    it 'escapes a plain (non-linked) value' do
      expect(helper.field('Resource Type', 'Sound & vision'))
        .to eq('<dt>Resource Type</dt><dd>Sound &amp; vision</dd>')
    end
  end
end
