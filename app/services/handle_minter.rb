# frozen_string_literal: true

# Mint the persistent identifier for a finalized Work and record it on the
# resource. The handle is "<prefix>/<noid>": reusing the NOID as the suffix
# makes it deterministic and trivially correlated to the object, so no
# separate suffix counter has to be kept or preserved.
#
# Best-effort by design. /complete is load-bearing in DRS — re-finalization
# is routine, and a bulk deposit leans on it — so a handle server that is
# down, slow, or misconfigured must not be able to fail a finalize. Every
# failure is logged and swallowed, leaving the Work unminted for a later
# /complete to pick up.
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
    return work if work.nil? || work.handle.present?
    return work unless mintable?

    mint(work)
  end

  private

    def mint(work)
      work.handle = @client.mint(work.noid, url: target_url(work))
      Atlas.persister.save(resource: work)
    rescue HandleClient::Error => e
      Rails.logger.warn("HandleMinter: #{work.noid} not minted — #{e.message}")
      work
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
