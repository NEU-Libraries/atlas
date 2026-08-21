# frozen_string_literal: true

# The two-tag "enhanced text" vocabulary a curator can put inside a MODS text
# node, and the one place both halves of its handling agree on that vocabulary.
#
# MODS has no element for a subscript, so a chemistry or physics record writes
# one by escaping the tags into the title's own text node. Read back, the title
# *value* is the literal string "Bi<sub>2</sub>Sr<sub>2</sub>CaCu<sub>2</sub>O<sub>8</sub>".
# A reader looking at that title needs the markup rendered; a reader searching
# for it types "Bi2Sr2CaCu2O8" and needs the markup gone. Those are opposite
# treatments of one string, so the allowlist lives here and both paths read it:
# whatever the display path renders is exactly what the match path removes.
module EnhancedText
  # Only these two. Anything else a curator types is an attempt to make the
  # metadata "pretty"; render shows it as source text rather than obeying it.
  TAGS = %w[sub sup].freeze

  # An opening or closing tag, attributes and all. The match form has to
  # tolerate a record that wrote attributes, because a sort or match key must
  # not carry `class="x"` either.
  TAG_PATTERN = %r{</?(?:#{TAGS.join('|')})\b[^>]*>}i

  # The three characters an HTML text node has to escape. Deliberately not the
  # quote characters: those only matter inside an attribute value, a rendered
  # value is always element text, and leaving them alone keeps linkify's URL
  # detection working on a URL that contains one.
  ESCAPES = { '&' => '&amp;', '<' => '&lt;', '>' => '&gt;' }.freeze
  ESCAPE_PATTERN = /[&<>]/

  # An allowlisted tag in its escaped form, and BARE -- no attributes. This is
  # what makes render safe: the escaped form of a tag carrying anything at all
  # (`<sub onmouseover=...>`) cannot match, so it can never be revived.
  ESCAPED_TAG = %r{&lt;(/?)(#{TAGS.join('|')})&gt;}i

  # The markup removed, the text kept -- "Bi<sub>2</sub>" becomes "Bi2".
  # Deliberately not a general HTML strip: a title is free text where "<" can
  # be a literal character ("Ti < Tc"), and removing only the two tags we
  # render cannot damage one of those.
  def self.strip(value)
    value.to_s.gsub(TAG_PATTERN, '')
  end

  # The inverse of strip: keep the two tags as markup and render every other
  # character as itself.
  #
  # Escaping first and reviving only the allowlist is the whole point. Handing
  # the value to an HTML parser instead means a literal "<" followed by a letter
  # opens a bogus element that swallows everything up to the next ">" -- a title
  # holding "Ti <Tc in Bi<sub>2</sub>O" lost 20 characters AND its subscript,
  # and how much vanished depended on where the next ">" happened to fall. A
  # record that correctly escapes its less-than as "&lt;Tc" produces exactly
  # that text, so well-formed MODS was the trigger.
  #
  # The cost of the trade is that a tag outside the allowlist now shows as
  # source text rather than being tidied away. For a preservation system that is
  # the better failure: a curator can see the mistake and fix the record.
  def self.render(value)
    value.to_s
         .gsub(ESCAPE_PATTERN, ESCAPES)
         .gsub(ESCAPED_TAG) { "<#{Regexp.last_match(1)}#{Regexp.last_match(2).downcase}>" }
  end
end
