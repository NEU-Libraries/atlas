# frozen_string_literal: true

# The shape rules for a handle, shared by the minter and by a create that
# brings a handle the Work already owns. See docs/handles.md.
module HandleIdentifier
  # `<prefix>/<suffix>`: a dotted numeric prefix, then any suffix without
  # whitespace.
  SHAPE = %r{\A\d+(\.\d+)*/\S+\z}

  # ANY host counts: v1 wrote http://hdl.handle.net, and a deployment can
  # resolve through its own proxy.
  def self.bare(text)
    text.to_s.strip.sub(%r{\Ahttps?://[^/]+/}i, '')
  end

  def self.valid?(handle)
    SHAPE.match?(handle.to_s)
  end
end
