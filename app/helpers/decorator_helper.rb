# frozen_string_literal: true

require 'cgi'
require 'sanitize'
require 'uri'

module DecoratorHelper
  include ActionView::Helpers # Seems to be neccessary due to Atlas being an API app

  # Inline tags that survive sanitisation. We deliberately omit <br>, <a>,
  # and structural tags: <br>'s are minted from blank lines by linkify
  # itself, <a>'s come from URL detection, and structural tags (<dt>, <dd>,
  # <p>) are emitted by the decorator. Any of these typed by curators get
  # stripped -- the goal is to prevent attempts to make metadata "pretty".
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
  URL_TRAILING_PUNCT_RE = /[).,;:!?'"\]]+\z/

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
  #   2. Convert blank-line paragraph breaks into <br><br>; treat lone
  #      newlines as soft wraps (collapsed to a space). Caps vertical
  #      whitespace at exactly one paragraph break regardless of input.
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
      html.gsub(/\n{2,}/, '<br><br>').tr("\n", ' ')
    end

    # html is already sanitised (only <sup>/<sub> tags survive, plus
    # <br><br> we just inserted). Walk it as a stream, splitting around
    # tags. Tags pass through untouched; text segments get URL detection
    # with non-URL text re-escaped.
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
        out << render_url_match(m[0])
        remainder = m.post_match
      end
      out << remainder
      out
    end

    def render_url_match(match)
      candidate, trailing = strip_trailing_punct(match)
      decoded = CGI.unescapeHTML(candidate)
      uri = safe_uri(decoded)
      head = uri ? link_tag(decoded, uri) : candidate
      head + trailing
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
