# frozen_string_literal: true

# Puts a Work's handle into a MODS document as its `hdl` identifier, shared by
# HandleMinter and by a whole-document MODS write. See docs/handles.md.
class HandleInMODS
  # The global proxy every registered prefix resolves through. A dev stack
  # homes an unregistered prefix and overrides this with its own server.
  DEFAULT_RESOLVER_BASE = 'https://hdl.handle.net'

  def initialize(noid:, handle:, resolver_base: ENV.fetch('HANDLE_RESOLVER_BASE', nil))
    @noid          = noid
    @handle        = handle
    @resolver_base = resolver_base.presence || DEFAULT_RESOLVER_BASE
  end

  # The new XML, or nil when there is nothing to write: every write appends an
  # OCFL version, so a no-op must cut none.
  def call(xml)
    doc  = Nokogiri::XML(xml, &:noblanks)
    node = identifier_node(doc)
    return nil if node.nil? || keep_existing?(node)

    node.content = permanent_url
    doc.to_s
  end

  # The citable form, and what the document records. The identifier carries the
  # resolver URL, as v1's records do; the bare handle is the Work's attribute.
  def permanent_url
    "#{@resolver_base.chomp('/')}/#{@handle}"
  end

  private

    # A document naming a DIFFERENT handle keeps it: both values are true, and
    # a preservation copy does not discard a true statement. Adopting the
    # document's value instead would spread one fixture's handle across every
    # Work built from it.
    #
    # A URL for this same handle is kept whatever host it names. Only a bare
    # handle is replaced, which heals a document written before the URL shape.
    def keep_existing?(node)
      current = node.text.strip
      return false if current.empty? || current == @handle
      return true if HandleIdentifier.bare(current) == @handle

      Rails.logger.warn("HandleInMODS: #{@noid} MODS carries handle #{current}, left in place over #{@handle}")
      true
    end

    # The template ships an hdl identifier, but a caller-assembled document
    # need not. MODS 3-5 puts no order on top-level elements, so appending is
    # safe.
    def identifier_node(doc)
      existing = doc.at_xpath("/mods:mods/mods:identifier[@type='hdl']", NEU::MODS::NAMESPACE)
      return existing if existing

      root = doc.at_xpath('/mods:mods', NEU::MODS::NAMESPACE)
      return nil if root.nil?

      node = doc.create_element('identifier', 'type' => 'hdl', 'displayLabel' => 'Permanent URL')
      node.namespace = root.namespace
      root.add_child(node)
      node
    end
end
