# frozen_string_literal: true

require 'cgi'
require 'sanitize'
require 'uri'

module DecoratorHelper
  include ActionView::Helpers # Seems to be neccessary due to Atlas being an API app

  # Inline tags that survive sanitisation. We deliberately omit <br>, <a>,
  # and structural tags: <a>'s come from URL detection, <p>'s are minted
  # from blank-line paragraph breaks by linkify itself, and other
  # structural tags (<dt>, <dd>) are emitted by the decorator. Any of
  # these typed by curators get stripped -- the goal is to prevent
  # attempts to make metadata "pretty".
  LINKIFY_ALLOWED_TAGS = %w[sup sub].freeze

  # Sanitize's default :whitespace_elements config inserts whitespace where
  # block-level tags get stripped (so "<p>a</p><p>b</p>" doesn't render as
  # "ab"). For curator metadata that's the wrong behaviour: typed <br><br>
  # would survive as runs of literal whitespace. Override every default
  # whitespace element with empty before/after so stripped tags vanish
  # silently. Sanitize::Config.merge does a deep merge, so passing {} here
  # would be a no-op -- each key has to be set explicitly.
  QUIET_WHITESPACE_ELEMENTS = Sanitize::Config::DEFAULT[:whitespace_elements].keys
                                                                             .index_with do |_el|
    { before: '', after: '' }
  end.freeze

  LINKIFY_SANITIZE_CONFIG = {
    elements: LINKIFY_ALLOWED_TAGS,
    attributes: {},
    remove_contents: %w[script style],
    whitespace_elements: QUIET_WHITESPACE_ELEMENTS
  }.freeze

  URL_CANDIDATE_RE = %r{https?://[^\s<>]+}
  # Brackets (), [], {} are *not* in here -- bracket balance is owned by
  # split_at_url_boundary, which preserves matched pairs (Wikipedia-style
  # "Foo_(disambiguation)") and peels stray closers off into the trailing
  # text. Only sentence terminators belong here.
  URL_TRAILING_PUNCT_RE = /[.,;:!?'"]+\z/

  def prefix_field(prefix, field)
    return prefix + field if field.present?

    ''
  end

  def loop_field(title, fields)
    return '' if fields.blank?

    result = tag.dt(title)
    fields.each do |f|
      result += tag.dd(linkify(f))
    end
    result
  end

  # Render curator-authored freetext as a safe HTML fragment:
  #   1. Sanitize against a tiny inline whitelist (sup/sub only).
  #   2. Split on blank-line paragraph breaks and wrap each paragraph in
  #      <p>...</p>; treat lone newlines as soft wraps (collapsed to a
  #      space). Emits <p> uniformly so consumers like Cerberus can own
  #      vertical spacing via CSS.
  #   3. Auto-link http(s) URLs that survive a strict URI.parse validation.
  #      Anything that fails to parse stays as plain (escaped) text.
  #   4. Mark the result html_safe.
  def linkify(text)
    return ''.html_safe if text.blank?

    sanitized = Sanitize.fragment(text.to_s, LINKIFY_SANITIZE_CONFIG)
    paragraphed = paragraphize(sanitized)
    # rubocop:disable Rails/OutputSafety -- html_safe is the entire purpose
    # of this method: every text segment came out of Sanitize escaped, every
    # surviving tag is from our tiny whitelist or our own injection, and
    # autolink only emits <a> tags via link_tag which escapes both href and
    # text content. Treating the result as html_safe is the correctness
    # guarantee we are paid to provide.
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

    # html is already sanitised (only <sup>/<sub> tags survive, plus
    # <p>...</p> wrappers we just inserted). Walk it as a stream, splitting
    # around tags. Tags pass through untouched; text segments get URL
    # detection with non-URL text re-escaped.
    def autolink(html)
      segments = html.split(/(<[^>]+>)/)
      segments.map { |seg| seg.start_with?('<') ? seg : autolink_text(seg) }.join
    end

    # Text segments come from Sanitize's output, so they are already HTML-
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
