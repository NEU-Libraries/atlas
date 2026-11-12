# frozen_string_literal: true

class WorkCreator < ApplicationService
  # Provenance kwargs are all optional so direct callers (specs,
  # reset.rake, ApplicationService.call from internal code) don't have to
  # synthesize an authenticated identity. The HTTP path (WorksController)
  # supplies them for every real-world create, which is when the
  # AuditEvent row is emitted.
  # Each kwarg is a distinct dimension of "what this create is" (parent,
  # body, provenance, audit attribution). Compressing into a hash would
  # hide the public contract.
  #
  # `handle:` is a handle the Work already owns, recorded as supplied so that
  # /complete mints nothing for it. Who may send one is the controller's
  # decision; the shape and uniqueness rules live here so every caller gets
  # them. See docs/handles.md. `legacy_pid:` follows the same split; see
  # docs/legacy-pids.md.
  def initialize(parent_id:, mods_xml: nil, proxy_uploader: nil, depositor: nil,
                 actor_nuid: nil, on_behalf_of_nuid: nil, handle: nil, legacy_pid: nil)
    @parent_id = resolve_id(parent_id)
    @handle    = handle.nil? ? nil : HandleIdentifier.bare(handle)
    @legacy_pid        = legacy_pid
    @mods_xml          = mods_xml.nil? ? mods_template : mods_xml
    @proxy_uploader    = proxy_uploader
    @depositor         = depositor
    @actor_nuid        = actor_nuid
    @on_behalf_of_nuid = on_behalf_of_nuid
  end

  def call
    LegacyPid.claim(@legacy_pid) { create_with_handle }
  end

  private

    def create_with_handle
      return create_work if @handle.nil?

      refuse_invalid_handle!
      with_handle_lock do
        refuse_taken_handle!
        create_work
      end
    end

    # The handle and the pid go on the FIRST save, so no moment exists in which
    # the Work is visible without them.
    def create_work
      work = Atlas.persister.save(resource: Work.new(a_member_of: @parent_id, legacy_pid: @legacy_pid,
                                                     **handle_attributes))

      FileSetCreator.call(work_id: work.id, classification: Classification.descriptive_metadata)

      work.mods_xml = @mods_xml

      # Order matters: permissions = parent.permissions copies the parent's
      # depositor / proxy_uploader fields onto this Work. Any provenance
      # stamping for *this* create has to land AFTER the copy, or the
      # parent's values will overwrite it.
      work.permissions = work.parent.permissions
      apply_provenance!(work)
      work.add_edit_group(Permissions::STAFF_EDIT_GROUP) # Default entry so DPS can work with all items
      work = Atlas.persister.save(resource: work)
      work.write_preservation_envelope!
      emit_audit_event!(work)
      work
    end

    def apply_provenance!(work)
      return apply_impersonation_provenance!(work) if @on_behalf_of_nuid.present?
      return if @proxy_uploader.nil? && @depositor.nil?

      work.proxy_uploader = @proxy_uploader if @proxy_uploader
      work.depositor      = @depositor      if @depositor
      # Self-deposit fallback: caller supplied only proxy_uploader and
      # the parent didn't carry a depositor — stamp the actor as
      # depositor too. The common case for non-proxy deposits.
      work.depositor ||= @proxy_uploader
    end

    # Acting-as: a pure impersonation deposit reads exactly as if the target
    # deposited it — depositor = target,
    # proxy_uploader explicitly NULL (the admin lives only in the AuditEvent,
    # not on the resource). proxy_uploader is cleared rather than skipped
    # because the parent.permissions copy upstream may have seeded an
    # inherited value. Contrast the proxy-deposit path (no On-Behalf-Of),
    # where proxy_uploader = the operator and must be preserved.
    def apply_impersonation_provenance!(work)
      work.proxy_uploader = nil
      work.depositor      = @depositor if @depositor
      work.depositor    ||= @on_behalf_of_nuid
    end

    def handle_attributes
      return {} if @handle.nil?

      { handle: @handle, handle_source: 'supplied' }
    end

    def refuse_invalid_handle!
      return if HandleIdentifier.valid?(@handle)

      raise Exceptions::SuppliedHandleError.new(
        :invalid_handle, "#{@handle.inspect} is not a handle; send <prefix>/<suffix>, e.g. 2047/d20001234"
      )
    end

    # Tombstoned Works count: their handles still resolve, and citations rest
    # on them.
    def refuse_taken_handle!
      holder = Atlas.query.custom_queries.find_works_by_handle(handle: @handle).first
      return if holder.nil?

      raise Exceptions::SuppliedHandleError.new(:handle_taken, "Work #{holder.noid} already holds #{@handle}")
    end

    # Serializes creates that bring the SAME handle, so two concurrent ones
    # cannot both pass the uniqueness check. A session lock and not a
    # transaction: the create also writes Solr and OCFL, which no Postgres
    # rollback could undo.
    def with_handle_lock
      connection = ActiveRecord::Base.connection
      key = ActiveRecord::Base.sanitize_sql_array(['hashtext(?), hashtext(?)', 'work_handle', @handle])
      connection.execute("SELECT pg_advisory_lock(#{key})")
      begin
        yield
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{key})")
      end
    end

    def emit_audit_event!(work)
      return if @actor_nuid.blank?

      on_behalf = @on_behalf_of_nuid || attribution_target(work)
      AuditEventWriter.record(
        resource:          work,
        actor_nuid:        @actor_nuid,
        on_behalf_of_nuid: on_behalf,
        action:            'create',
        change_type:       'structural',
        event_source:      'controller'
      )
      # A Work always has a parent, so its starting ACL is always inherited.
      emit_permissions_grant!(work, actor_nuid: @actor_nuid, on_behalf_of_nuid: on_behalf,
                                    source: 'inherited', parent_noid: work.parent&.noid)
    end

    # When on_behalf_of wasn't supplied explicitly but the depositor
    # differs from the actor, the depositor *is* the implicit attribution
    # target (e.g., the in-band proxy radio case in WorksController).
    def attribution_target(work)
      return nil if work.depositor.blank?
      return nil if work.depositor == @actor_nuid

      work.depositor
    end
end
