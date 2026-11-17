# frozen_string_literal: true

# Mints the persistent identifier for a finalized Work and records it both on
# the resource and as the MODS `hdl` identifier. See docs/handles.md.
#
# Best-effort at the MINT and only there: /complete is load-bearing, so a
# handle server that is down must not fail a finalize. The MODS write is local
# and raises.
#
# The MODS write runs on EVERY call, not only on a call that mints -- that is
# what heals a Work minted before this service existed.
class HandleMinter < ApplicationService
  def initialize(work:, client: HandleClient.new,
                 public_base: ENV.fetch('CERBERUS_PUBLIC_BASE', nil),
                 resolver_base: ENV.fetch('HANDLE_RESOLVER_BASE', nil))
    @work          = work
    @client        = client
    @public_base   = public_base.presence
    @resolver_base = resolver_base
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
    # in the repository could re-derive. The envelope follows the save: it is
    # the handle's only record on disk, so a rebuild without it loses the
    # binding every outside citation rests on.
    # The save retries: the handle is live by then. See docs/handles.md.
    def mint(work)
      handle = @client.mint(work.noid, url: target_url(work))
      StaleRetry.run("record handle #{handle} on #{work.noid}") do |attempt|
        work = reload(work) if attempt.positive?
        next work if work.handle.present?

        work.handle        = handle
        work.handle_source = 'minted'
        Atlas.persister.save(resource: work)
      end.tap(&:write_preservation_envelope!)
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

      # Reads the document under the MODS lock, so a concurrent upload's edit survives.
      StaleRetry.run("record handle in MODS of #{work.noid}") do |attempt|
        work = reload(work) if attempt.positive?
        work.update_mods_xml { |xml| mods_with_identifier(work, xml) }
      end
    end

    def mods_with_identifier(work, xml)
      HandleInMODS.new(noid: work.noid, handle: work.handle, resolver_base: @resolver_base).call(xml)
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
