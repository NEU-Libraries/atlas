# frozen_string_literal: true

# Unwraps the browse markers from a rendered MODS row, so a spec about which
# ROW a value lands in reads as the row rather than as the span around it.
#
# Held apart rather than folded into those specs on purpose: the markers are
# themselves a contract, asserted directly in the "browse markers" block, and a
# spec asserting both at once fails on a marker change for a reason that has
# nothing to do with what it is checking. The neu-mods projection specs split
# the same way, through #without_display_attributes.
module BrowseMarkerHelper
  BROWSE_SPAN = %r{<span data-browse-[^>]*>(.*?)</span>}m

  def without_browse_markers(html)
    html.to_s.gsub(BROWSE_SPAN) { Regexp.last_match(1) }
  end
end

RSpec.configure { |config| config.include BrowseMarkerHelper }
