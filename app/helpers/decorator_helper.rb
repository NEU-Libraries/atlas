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

  # HTML5 gives an anchor a transparent content model, so wrapping the
  # paragraphs of an abstract is valid and the paragraphing survives the link.
  def linked_value(value, href, paragraphs: true)
    rendered = paragraphs ? linkify(value) : enhanced_text(value)
    return rendered if href.blank?

    tag.a(rendered, href: href, rel: 'nofollow noopener', target: '_blank')
  end

  # `text` is what a reader sees, `value:` is what the index holds, and they
  # are NOT the same string in general -- a language row reads "Spanish
  # (subtitles)" against an indexed "Spanish". A consumer matching on rendered
  # text would miss it, so the indexed value is stated rather than inferred.
  #
  # A value the RECORD linked with xlink:href takes no marker: a consumer
  # wrapping it would nest <a> inside <a>. See docs/mods-display.md.
  def browse_value(text, axis, value: text, authority: nil, href: nil)
    return linked_value(text, href) if axis.nil? || href.present?

    data = { browse_axis: axis.browse, browse_value: value }
    data[:browse_authority] = authority if authority.present?
    tag.p(tag.span(enhanced_text(text), data: data))
  end

  # Nothing at all when the value is blank, so a sparse record shows no empty
  # <dd>. The label is resolved by the CALLER: which of @displayLabel,
  # @eventType and the field name wins differs per field.
  def labeled_field(label, value, href: nil, paragraphs: true)
    return '' if value.blank?

    tag.dt(label) + tag.dd(linked_value(value, href, paragraphs: paragraphs))
  end

  # Values here are ALREADY rendered HTML. Running them through linkify again
  # would escape the anchors it just produced.
  def html_field(label, rendered)
    return '' if rendered.blank?

    rendered.reduce(tag.dt(label)) { |row, value| row + tag.dd(value) }
  end

  # A single-line value -- a title. Same allowlist as linkify, without its
  # paragraph wrapper or URL detection: a <p> inside the <dd> would change a
  # shape every consumer of the MODS HTML block already lays out.
  def enhanced_text(value)
    return ''.html_safe if value.blank?

    # rubocop:disable Rails/OutputSafety -- render escapes the value and then
    # revives only a bare <sub>/<sup>, so the two tags of the allowlist are
    # the only markup the result can possibly contain.
    EnhancedText.render(value).html_safe
    # rubocop:enable Rails/OutputSafety
  end

  # Escape, revive only a bare <sup>/<sub>, paragraph on blank lines (lone
  # newlines are soft wraps), then autolink URLs that survive a strict
  # URI.parse. <p> is emitted uniformly so Cerberus can own spacing via CSS.
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

    # Input is already escaped, so this walks it as a stream: tags pass
    # through untouched, text segments get URL detection and re-escaping.
    def autolink(html)
      segments = html.split(/(<[^>]+>)/)
      segments.map { |seg| seg.start_with?('<') ? seg : autolink_text(seg) }.join
    end

    # Segments are already HTML-escaped ('&' is '&amp;'), so a URL match has
    # to be entity-decoded to recover the real URL before validating it.
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

    # The URL regex is greedy and stops only at whitespace, so the first
    # closing bracket with no matching opener inside the URL is where the URL
    # really ends. Keeps "Foo_(disambiguation)" intact while peeling off a
    # stray ")Copyright...".
    BRACKET_PAIRS = { ')' => '(', ']' => '[', '}' => '{' }.freeze
    private_constant :BRACKET_PAIRS

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
