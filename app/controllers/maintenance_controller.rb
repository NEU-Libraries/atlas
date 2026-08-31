# frozen_string_literal: true

class MaintenanceController < ApplicationController
  # Reset is the test/dev bootstrap escape hatch. It deliberately runs
  # unauthenticated — the Rails.env guard inside the action is the only
  # gate. Wiring auth on it would break the bootstrap chicken-and-egg:
  # the action wipes and re-seeds the fixture users, so the very first
  # call against a fresh test container has nobody to authenticate as.
  # The piece-7 `authorize! :reset, :maintenance` is replaced by
  # `skip_authorization_check` so the ApplicationController-level
  # `check_authorization` after_action doesn't trip.
  skip_before_action :require_auth, only: :reset
  skip_authorization_check only: :reset

  # Reset skips authorize! entirely, so the maintenance floor in
  # ApplicationController#authorize! never sees it. It is the most destructive
  # write Atlas has, so it gets the check explicitly rather than an exemption;
  # its RESETTABLE_ENVS guard is a separate concern.
  before_action :refuse_during_maintenance, only: :reset

  # Reset is restricted to ephemeral environments; production is never wiped.
  RESETTABLE_ENVS = %w[development staging test].freeze

  # GET /maintenance — the window's state. On the authenticated read floor, and
  # deliberately so: if this were refused during maintenance, Cerberus could
  # never see the flag it is meant to be honouring.
  def show
    authorize! :read, :maintenance

    @maintenance = MaintenanceMode.current
    render 'maintenance/show'
  end

  # PUT /maintenance — open or close the window. :system + admin, matching how
  # the token endpoints gate an operator action.
  #
  # The one action that stays reachable while the window is open (see
  # #read_only_exempt? below) — otherwise the window could never be closed.
  def update
    authorize! :maintain, :maintenance

    read_only = ActiveModel::Type::Boolean.new.cast(params[:read_only])
    return render_error(:bad_request, 'read_only is required') if read_only.nil?

    # An unnamed door is a human at the hub or the console, and a human may close
    # either kind of window. The deploy orchestrator names itself, and is the only
    # door whose close is restricted.
    source = params[:source].presence || 'operator'
    return render_error(:bad_request, "unknown source #{source}") unless MaintenanceMode::SOURCES.include?(source)

    @maintenance = if read_only
                     MaintenanceMode.open!(source: source, message: params[:message].presence,
                                           retry_after: params[:retry_after].presence&.to_i)
                   else
                     MaintenanceMode.close!(source: source)
                   end
    audit_maintenance_event
    render 'maintenance/show'
  end

  def reset
    raise "Wrong env - #{Rails.env} - must not be production" unless resettable_env?

    DatabaseCleaner.strategy = :deletion
    DatabaseCleaner.clean

    # SolrCore.url, not a literal: reset must wipe the core the composite
    # persister writes to, and in test that core is env-driven per instance.
    c = RSolr.connect(url: SolrCore.url)

    c.delete_by_query '*:*'
    c.commit

    # The DB wipe above resets the NOID minter, so the next seed re-mints the
    # same NOID sequence — and without this purge those reminted ids resolve to
    # the SAME on-disk OCFL objects as prior runs. OCFL state is cumulative, so
    # each run's descMetadata.xml / binaries would stack onto the prior run's
    # object, polluting a resource's MODS history with other resources' content
    # across runs. Emptying the storage root makes every reseeded object start
    # at v1 with only its own content.
    purge_storage!
    seed_fixture_users!
  end

  private

    def refuse_during_maintenance
      raise Exceptions::ReadOnlyMode if MaintenanceMode.read_only?
    end

    # PUT /maintenance is the sole action exempt from the maintenance floor in
    # ApplicationController#authorize!. Without it an open window would refuse
    # the very request that closes it.
    def read_only_exempt?
      action_name == 'update'
    end

    # PUT /maintenance is :system-gated, so without this the ledger would record
    # the system principal flipping the flag and not who asked. "Who put the
    # repository into maintenance mode, and when" is exactly the sort of fact the
    # ledger should hold. Mirrors Users::TokensController#audit_token_event, which
    # has the same system-gated-but-human-driven shape.
    def audit_maintenance_event
      AuditEventWriter.record(
        actor_nuid:        @current_user.nuid,
        on_behalf_of_nuid: @on_behalf_of,
        action:            @maintenance.read_only? ? 'open_maintenance_window' : 'close_maintenance_window',
        change_type:       'maintenance',
        event_source:      'controller',
        payload:           { source: @maintenance.source, message: @maintenance.message }.compact
      )
    end

    def seed_fixture_users!
      # non-human bookends — single-row each by design
      create_fixture_user(name: 'User, System', nuid: '000000000',
                          email: 'admin@northeastern.edu', role: :system)
      create_fixture_user(name: 'User, Anonymous', nuid: '000000099',
                          email: 'anonymous@northeastern.edu', role: :anonymous)

      # human roles — dev fixtures exercising each tier of the gradient
      create_fixture_user(name: 'User, Guest', nuid: '000000001',
                          email: 'guest@northeastern.edu', role: :guest)
      # Plain Northeastern depositor tier: no Grouper groups, not an owner of the
      # seed tree — isolates the standard-vs-staff boundary (e.g. request_change,
      # whose UI control only appears to a non-editor/owner of a work).
      create_fixture_user(name: 'User, Standard', nuid: '000000005',
                          email: 'standard@northeastern.edu', role: :standard,
                          groups: ['northeastern:drs:library:dsg_students'])
      create_fixture_user(name: 'User, Standard', nuid: '000000005',
                          email: 'standard@husky.neu.edu', role: :standard,
                          groups: ['northeastern:drs:all'])
      create_fixture_user(name: 'Doe, Jane', nuid: '000000002', role: :privileged,
                          email: 'dps@northeastern.edu',
                          groups: ['northeastern:drs:repository:staff', 'northeastern:drs:repository:api', 'northeastern:drs:repository:admin'])
      create_fixture_user(name: 'Williams, Susan', nuid: '000000006', role: :privileged,
                          email: 'susan@northeastern.edu',
                          groups: ['northeastern:drs:repository:staff', 'northeastern:drs:repository:api'])
      create_fixture_user(name: 'Loader, Marcom', nuid: '000000003', role: :loader,
                          email: 'marcom-loader@northeastern.edu',
                          groups: ['northeastern:drs:repository:loaders:marcom'])
      create_fixture_user(name: 'User, Admin', nuid: '000000004',
                          email: 'drs-admin@northeastern.edu', role: :admin,
                          groups: ['northeastern:drs:repository:admin'])
    end

    def create_fixture_user(**attrs)
      User.create(password: Devise.friendly_token[0, 20], **attrs)
    end

    def resettable_env?
      RESETTABLE_ENVS.include?(Rails.env.to_s)
    end

    # Empty every on-disk Valkyrie (OCFL) storage root, leaving each directory
    # itself in place (it is a container mount point). Children are removed
    # rather than the root so the adapter's path stays valid for the re-seed.
    def purge_storage!
      # Independent of the caller's guard, because this rm_rf targets the
      # preservation root — never let it be reachable outside a resettable env.
      raise "refusing to purge OCFL storage outside a resettable env (#{Rails.env})" unless resettable_env?

      # An absent root just means "nothing to purge" — the OCFL adapter lazily
      # creates it on first write, so test's ephemeral tmp/files may not exist
      # yet on a freshly booted container. Create it so the guard's directory
      # check passes and the re-seed has a valid empty store; no-op when the root
      # already exists (dev/staging's mounted volume), so their behavior is
      # unchanged. The shallow-/unsafe-root guard runs per root, because one
      # misconfigured entry in the pool must not be reached through a sibling.
      Valkyrie.config.storage_adapter.storage_roots.each_value do |storage_root|
        root = storage_root.base_path
        FileUtils.mkdir_p(root)
        guard_storage_root!(root)
        FileUtils.rm_rf(root.children)
      end
    end

    # Refuse to operate on a missing, non-directory, or dangerously shallow root
    # (e.g. `/` or a single-segment path). The real roots — /home/atlas/storage
    # and <app>/tmp/files — are absolute and several segments deep, so a root
    # with fewer than two path segments signals a misconfiguration we must not
    # rm_rf against.
    def guard_storage_root!(root)
      raise "storage root missing or not a directory: #{root.inspect}" unless root && File.directory?(root)
      raise "refusing to purge unsafe storage root: #{root.inspect}" if root.cleanpath.each_filename.to_a.length < 2
    end
end
