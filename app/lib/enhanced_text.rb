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
  # metadata "pretty", and DecoratorHelper's sanitiser drops it.
  TAGS = %w[sub sup].freeze

  # An opening or closing tag, attributes and all: the display sanitiser keeps
  # the tag and discards its attributes, so the match form has to tolerate a
  # record that wrote them.
  TAG_PATTERN = %r{</?(?:#{TAGS.join('|')})\b[^>]*>}i

  # The markup removed, the text kept -- "Bi<sub>2</sub>" becomes "Bi2".
  # Deliberately not a general HTML strip: a title is free text where "<" can
  # be a literal character ("Ti < Tc"), and removing only the two tags we
  # render cannot damage one of those.
  def self.strip(value)
    value.to_s.gsub(TAG_PATTERN, '')
  end
end
