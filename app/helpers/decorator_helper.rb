# frozen_string_literal: true

require 'cgi'
require 'uri'

module DecoratorHelper
  include ActionView::Helpers # Seems to be neccessary due to Atlas being an API app

  URL_CANDIDATE_RE = %r{https?://[^\s<>]+}
  # Brackets (), [], {} are *not* in here -- bracket balance is owned by
  # split_at_url_boundary, which preserves matched pairs (Wikipedia-style
  # "Foo_(disambiguation)") and peels stray closers off into the trailing
  # text. Only sentence terminators belong here.
  URL_TRAILING_PUNCT_RE = /[.,;:!?'"]+\z/

  # A value with the link the record attached to it (xlink:href), or the value
  # alone. HTML5 gives an anchor a transparent content model, so wrapping the
  # paragraphs of an abstract is valid and the paragraphing survives the link.
  #
  # The text goes through the same rendering as any unlinked value, so a
  # subscript in a title and a URL inside an abstract still work; tag.a
  # escapes the href.
  def linked_value(value, href, paragraphs: true)
    rendered = paragraphs ? linkify(value) : enhanced_text(value)
    return rendered if href.blank?

    tag.a(rendered, href: href, rel: 'nofollow noopener', target: '_blank')
  end

  # A value marked with the browse it belongs to, for a consumer that injects
  # this HTML whole and has no other per-value handle on it. The <span> carries
  # the semantic axis, the EXACT string the index holds, and the vocabulary the
  # term came from when there is one.
  #
  # The marked value renders without the paragraph pass. A browse candidate is
  # a controlled term on one line -- a subject heading, a name, a genre -- so
  # there is no blank-line break to keep and no URL to autolink, and the <p>
  # wrapper is added here so the row keeps the shape every consumer of this
  # block already lays out.
  #
  # A value the RECORD linked with xlink:href takes no marker: it already has
  # an anchor, and a consumer wrapping the marker in a second one would nest
  # <a> inside <a>. The record's own link wins, because it is the more specific
  # claim.
  #
  # `text` is what a reader sees and `value:` is what the index holds. They are
  # NOT the same string in general and the difference is the point: a language
  # row reads "Spanish (subtitles)" against an indexed "Spanish", and a name
  # row carries its affiliation in brackets. A consumer matching on the
  # rendered text would miss both, which is why the indexed value is stated
  # rather than inferred.
  def browse_value(text, axis, value: text, authority: nil, href: nil)
    return linked_value(text, href) if axis.nil? || href.present?

    data = { browse_axis: axis.browse, browse_value: value }
    data[:browse_authority] = authority if authority.present?
    tag.p(tag.span(enhanced_text(text), data: data))
  end

  # One label and one value, or nothing at all when the value is blank -- so a
  # sparse record shows no empty <dd> under a heading like "Date created". The
  # label is resolved by the CALLER, because which of @displayLabel, @eventType
  # and the field's own name wins is display policy that differs per field.
  def labeled_field(label, value, href: nil, paragraphs: true)
    return '' if value.blank?

    tag.dt(label) + tag.dd(linked_value(value, href, paragraphs: paragraphs))
  end

  # One label over many values that are ALREADY rendered HTML, each having gone
  # through #linked_value. Running them through linkify again would escape the
  # anchors it just produced.
  def html_field(label, rendered)
    return '' if rendered.blank?

    rendered.reduce(tag.dt(label)) { |row, value| row + tag.dd(value) }
  end

  # Render a single-line curator-authored *value* -- a title -- as a safe HTML
  # fragment, so escaped <sub>/<sup> in a MODS text node reaches the reader as
  # a subscript instead of as visible tags. Same allowlist as linkify, without
  # its paragraph wrapper or URL detection: a title is one line, and a <p>
  # inside the <dd> would change a shape every consumer of the MODS HTML block
  # already lays out.
  def enhanced_text(value)
    return ''.html_safe if value.blank?

    # rubocop:disable Rails/OutputSafety -- render escapes the value and then
    # revives only a bare <sub>/<sup>, so the two tags of the allowlist are
    # the only markup the result can possibly contain.
    EnhancedText.render(value).html_safe
    # rubocop:enable Rails/OutputSafety
  end

  # Render curator-authored freetext as a safe HTML fragment:
  #   1. Escape the value, then revive only a bare <sup>/<sub>.
  #   2. Split on blank-line paragraph breaks and wrap each paragraph in
  #      <p>...</p>; treat lone newlines as soft wraps (collapsed to a
  #      space). Emits <p> uniformly so consumers like Cerberus can own
  #      vertical spacing via CSS.
  #   3. Auto-link http(s) URLs that survive a strict URI.parse validation.
  #      Anything that fails to parse stays as plain (escaped) text.
  #   4. Mark the result html_safe.
  def linkify(text)
    return ''.html_safe if text.blank?

    escaped = EnhancedText.render(text)
    paragraphed = paragraphize(escaped)
    # rubocop:disable Rails/OutputSafety -- html_safe is the entire purpose of
    # this method: render escaped every text segment, every surviving tag is
    # from our tiny allowlist or our own injection, and autolink only emits
    # <a> tags via link_tag, which escapes both href and text content.
    # Treating the result as html_safe is the correctness guarantee we are
    # paid to provide.
    autolink(paragraphed).html_safe
    # rubocop:enable Rails/OutputSafety
  end

  private

    def paragraphize(html)
      html.split(/\n{2,}/)
          .map { |para| para.tr("\n", ' ') }
          .compact_blank
          .map { |para| "<p>#{para}</p>" }
          .join
    end

    # html is already escaped (only <sup>/<sub> tags survive, plus
    # <p>...</p> wrappers we just inserted). Walk it as a stream, splitting
    # around tags. Tags pass through untouched; text segments get URL
    # detection with non-URL text re-escaped.
    def autolink(html)
      segments = html.split(/(<[^>]+>)/)
      segments.map { |seg| seg.start_with?('<') ? seg : autolink_text(seg) }.join
    end

    # Text segments come from render's output, so they are already HTML-
    # escaped (e.g. '&' has become '&amp;'). Pass surrounding text through
    # untouched. For URL matches, decode entities to recover the real URL,
    # validate it, and emit a properly-escaped <a> tag.
    def autolink_text(text)
      out = +''
      remainder = text
      while (m = remainder.match(URL_CANDIDATE_RE))
        out << m.pre_match
        rendered, after = render_url_match(m[0])
        out << rendered
        # 'after' is text the regex slurped past the real URL boundary;
        # prepend to the remainder so a second URL hidden in there still
        # gets matched on the next loop pass.
        remainder = after + m.post_match
      end
      out << remainder
      out
    end

    def render_url_match(match)
      candidate, after = split_at_url_boundary(match)
      candidate, trailing = strip_trailing_punct(candidate)
      decoded = CGI.unescapeHTML(candidate)
      uri = safe_uri(decoded)
      head = uri ? link_tag(decoded, uri) : candidate
      [head + trailing, after]
    end

    # The URL regex is greedy and only stops at whitespace, so a paste like
    # "(http://example.com)Copyright" matches everything from "http" to the
    # final 't'. Walk the match tracking bracket balance: the first closing
    # bracket without a matching opener inside the URL is where the URL
    # really ends. This keeps Wikipedia-style "Foo_(disambiguation)" URLs
    # intact while peeling off stray ")Copyright..." text that ran on past
    # the URL.
    BRACKET_PAIRS = { ')' => '(', ']' => '[', '}' => '{' }.freeze

    def split_at_url_boundary(str)
      depth = Hash.new(0)
      str.each_char.with_index do |ch, i|
        if (opener = BRACKET_PAIRS[ch])
          return [str[0...i], str[i..]] if depth[opener].zero?

          depth[opener] -= 1
        elsif BRACKET_PAIRS.value?(ch)
          depth[ch] += 1
        end
      end
      [str, '']
    end

    def strip_trailing_punct(str)
      if (m = str.match(URL_TRAILING_PUNCT_RE))
        [m.pre_match, m[0]]
      else
        [str, '']
      end
    end

    def safe_uri(str)
      uri = URI.parse(str)
      return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
      return nil if uri.host.blank? || uri.host.exclude?('.')

      uri
    rescue URI::InvalidURIError
      nil
    end

    def link_tag(text, uri)
      href = ERB::Util.html_escape(uri.to_s)
      label = ERB::Util.html_escape(text)
      %(<a href="#{href}" rel="nofollow noopener" target="_blank">#{label}</a>)
    end
end
