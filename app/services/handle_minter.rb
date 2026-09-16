# frozen_string_literal: true

# Mints the persistent identifier for a finalized Work and records it both on
# the resource and as the MODS `hdl` identifier. See docs/handles.md.
#
# Best-effort at the MINT and only there: /complete is load-bearing, so a
# handle server that is down must not fail a finalize. The MODS write is local
# and raises.
#
# The MODS write runs on EVERY call, not only on a call that mints -- that is
# what heals a Work whose document was later replaced through mods_xml=.
class HandleMinter < ApplicationService
  # The global proxy every registered prefix resolves through. A dev stack
  # homes an unregistered prefix and overrides this with its own server.
  DEFAULT_RESOLVER_BASE = 'https://hdl.handle.net'

  def initialize(work:, client: HandleClient.new,
                 public_base: ENV.fetch('CERBERUS_PUBLIC_BASE', nil),
                 resolver_base: ENV.fetch('HANDLE_RESOLVER_BASE', nil))
    @work          = work
    @client        = client
    @public_base   = public_base.presence
    @resolver_base = resolver_base.presence || DEFAULT_RESOLVER_BASE
  end

  def call
    work = reload
    return work if work.nil?

    work = mint(work) if work.handle.blank? && mintable?
    record_in_mods(work)
    work
  end

  private

    # ORDER MATTERS: the resource save comes first, so a document that refuses
    # the write still leaves a minted Work behind. The reverse order could
    # register a handle externally and keep no record of it here, which nothing
    # in the repository could re-derive.
    def mint(work)
      work.handle = @client.mint(work.noid, url: target_url(work))
      Atlas.persister.save(resource: work)
    rescue HandleClient::Error => e
      Rails.logger.warn("HandleMinter: #{work.noid} not minted — #{e.message}")
      work
    end

    # The identifier carries the RESOLVER URL, not the bare handle: that is
    # the shape v1's records hold, and the field neu-mods projects it onto is
    # named permanent_url. `work.handle` stays bare -- it is the identifier.
    def record_in_mods(work)
      return if work.handle.blank?
      return log_unwritable(work) unless work.mods_writable?

      xml = mods_with_identifier(work)
      work.mods_xml = xml unless xml.nil?
    end

    # nil when there is nothing to write. Skipping a no-op matters: every write
    # appends an OCFL version, so an unconditional one cuts a version that says
    # nothing new.
    def mods_with_identifier(work)
      doc  = Nokogiri::XML(work.mods_xml, &:noblanks)
      node = identifier_node(doc)
      return nil if node.nil? || keep_existing?(work, node)

      node.content = permanent_url(work)
      doc.to_s
    end

    # A document naming a DIFFERENT handle keeps it: both values are true, and
    # a preservation copy does not discard a true statement. Adopting the
    # document's value instead would spread one fixture's handle across every
    # Work built from it.
    #
    # A URL for this same handle is kept whatever host it names. Only a bare
    # handle is replaced, which heals a document written before the URL shape.
    def keep_existing?(work, node)
      current = node.text.strip
      return false if current.empty? || current == work.handle
      return true if handle_in(current) == work.handle

      Rails.logger.warn(
        "HandleMinter: #{work.noid} MODS carries handle #{current}, left in place over #{work.handle}"
      )
      true
    end

    # ANY host counts: v1 wrote http://hdl.handle.net, and a deployment can
    # resolve through its own proxy.
    def handle_in(text)
      text.sub(%r{\Ahttps?://[^/]+/}i, '')
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

    # A minted Work with no descriptive-metadata FileSet is malformed -- every
    # creator makes one -- so this logs rather than failing a finalize over a
    # document already broken before it ran.
    def log_unwritable(work)
      Rails.logger.warn("HandleMinter: #{work.noid} minted, no descriptive metadata to record #{work.handle} in")
      nil
    end

    # Cerberus knows its own host and Atlas does not, so the base is config.
    def target_url(work)
      "#{@public_base.chomp('/')}/works/#{work.noid}"
    end

    # The citable form, and what the document records.
    def permanent_url(work)
      "#{@resolver_base.chomp('/')}/#{work.handle}"
    end

    # The normal state for a test run and any stack without the handles
    # profile.
    def mintable?
      @client.configured? && @public_base.present?
    end

    # The caller's copy is stale by this point in /complete: the METS rebuild
    # wrote through the persister. Mirrors WorkMETSRebuilder.
    def reload(work = @work)
      return nil if work.nil?

      Work.find(work.respond_to?(:id) ? work.id : work)
    end
end
