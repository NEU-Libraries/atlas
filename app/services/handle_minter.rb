# frozen_string_literal: true

# Mint the persistent identifier for a finalized Work and record it in the two
# places that have to agree: the `handle` attribute on the resource, and the
# MODS `hdl` identifier that the descriptive template reserves for it. The
# handle is "<prefix>/<noid>": reusing the NOID as the suffix makes it
# deterministic and trivially correlated to the object, so no separate suffix
# counter has to be kept or preserved.
#
# Atlas writes that identifier itself rather than leaving it to the depositing
# client, because Atlas is the only party that knows the handle at the moment it
# exists, and /complete is the one choke point every deposit path crosses. A
# client-side merge would have to be repeated per path and would skip any
# depositor that is not Cerberus, which drifts the preservation copy by
# depositor. This does not reopen descriptive merges — those stay with the
# caller. Atlas fills a slot it generated the value for, as it does for METS.
#
# Best-effort at the mint, and only there. /complete is load-bearing in DRS —
# re-finalization is routine, and a bulk deposit leans on it — so a handle
# server that is down, slow, or misconfigured must not be able to fail a
# finalize; that failure is logged and swallowed, leaving the Work unminted for
# a later /complete to pick up. The MODS write earns no such licence: it is
# local, so it raises like the METS rebuild beside it in /complete.
#
# The MODS write runs on every call, not only on a call that mints. A Work
# minted before this existed, or one whose document was later replaced wholesale
# through `mods_xml=`, holds the attribute and not the identifier — running the
# reconciliation unconditionally is what heals both.
#
# Idempotent twice over: it skips a Work that already carries a handle, and
# the underlying PUT is keyed by handle name, so even a re-mint re-points an
# existing record rather than duplicating it.
class HandleMinter < ApplicationService
  def initialize(work:, client: HandleClient.new,
                 public_base: ENV.fetch('CERBERUS_PUBLIC_BASE', nil))
    @work        = work
    @client      = client
    @public_base = public_base.presence
  end

  def call
    work = reload
    return work if work.nil?

    work = mint(work) if work.handle.blank? && mintable?
    record_in_mods(work)
    work
  end

  private

    # The resource save comes first and the MODS write second, so a document
    # that refuses the write still leaves a minted Work behind. The reverse
    # order could register a handle on the external service and keep no record
    # of it here, which nothing in the repository could re-derive.
    def mint(work)
      work.handle = @client.mint(work.noid, url: target_url(work))
      Atlas.persister.save(resource: work)
    rescue HandleClient::Error => e
      Rails.logger.warn("HandleMinter: #{work.noid} not minted — #{e.message}")
      work
    end

    # Carry the handle into the descriptive metadata as the MODS `hdl`
    # identifier. The resource attribute alone reaches the API and the Work
    # page; MODS is what DRS exports, versions, hands to the XML editor and
    # serves over OAI-PMH, so an identifier absent from it is absent from all of
    # those. neu-mods projects this node onto Metadata::MODS#permanent_url, so
    # the JSON access copy fills from the same write rather than needing a
    # derived value of its own.
    #
    # The identifier carries the BARE handle. `type="hdl"` means the identifier
    # itself, not a resolver URL, and that is the shape v1 records hold.
    def record_in_mods(work)
      return if work.handle.blank?
      return log_unwritable(work) unless work.mods_writable?

      xml = mods_with_identifier(work)
      work.mods_xml = xml unless xml.nil?
    end

    # @return [String, nil] the document with its `hdl` identifier set to the
    #   handle, or nil when there is nothing to write. Skipping a no-op matters:
    #   every write appends an OCFL version to the descriptive metadata, so an
    #   unconditional one would cut a version that says nothing new.
    def mods_with_identifier(work)
      doc  = Nokogiri::XML(work.mods_xml, &:noblanks)
      node = identifier_node(doc)
      return nil if node.nil? || keep_existing?(work, node)

      node.content = work.handle
      doc.to_s
    end

    # Whether the document's identifier must be left as it stands: either it
    # already says this handle, or it says a different one.
    #
    # A different one means a v1 record migrated in under prefix 2047 whose
    # `handle` attribute was never set, so this minted a second identifier.
    # Both values are true — the v1 handle still resolves — and a preservation
    # copy does not get to discard a true statement, so the document keeps what
    # it has and the disagreement is logged. Adoption is deliberately not the
    # answer: reading an identity back out of a document any caller can assemble
    # would spread one fixture's handle across every Work built from it. The
    # migrator setting `handle` on ingest is what stops the second mint.
    def keep_existing?(work, node)
      current = node.text.strip
      return false if current.empty?
      return true if current == work.handle

      Rails.logger.warn(
        "HandleMinter: #{work.noid} MODS carries handle #{current}, left in place over #{work.handle}"
      )
      true
    end

    # The document's `hdl` identifier, created empty at the end of the root if
    # it has none. The MODS template ships one, but a caller-assembled document
    # (the XML editor, the loaders) need not, and MODS 3-5 puts no order on
    # top-level elements — so appending is safe.
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

    # A minted Work with no descriptive-metadata FileSet is malformed — every
    # creator makes one — so say so rather than raising and failing a finalize
    # over a document that was already broken before this ran.
    def log_unwritable(work)
      Rails.logger.warn("HandleMinter: #{work.noid} minted, no descriptive metadata to record #{work.handle} in")
      nil
    end

    # Where the handle sends a reader: the public Work page. Cerberus knows
    # its own host and Atlas does not, so the base arrives as config.
    def target_url(work)
      "#{@public_base.chomp('/')}/works/#{work.noid}"
    end

    # No server configured, or nowhere to point a handle at, means this
    # deployment does not mint. That is the normal state for a test run and
    # for any stack brought up without the handles profile.
    def mintable?
      @client.configured? && @public_base.present?
    end

    # Mirrors WorkMETSRebuilder: the caller's copy is stale by this point in
    # /complete, because the METS rebuild wrote through the persister.
    def reload(work = @work)
      return nil if work.nil?

      Work.find(work.respond_to?(:id) ? work.id : work)
    end
end
