# frozen_string_literal: true

class MaintenanceController < ApplicationController
  # Reset runs unauthenticated on purpose -- RESETTABLE_ENVS is the only gate.
  # Auth here would break a bootstrap chicken-and-egg: the action re-seeds the
  # fixture users, so the first call against a fresh container has nobody to
  # authenticate as. skip_authorization_check stops check_authorization
  # tripping on an action that never calls authorize!.
  skip_before_action :require_auth, only: :reset
  skip_authorization_check only: :reset

  # Skipping authorize! means the maintenance floor never sees reset, so the
  # most destructive write Atlas has gets the check explicitly.
  before_action :refuse_during_maintenance, only: :reset

  # Reset is restricted to ephemeral environments; production is never wiped.
  RESETTABLE_ENVS = %w[development staging test].freeze

  # Rails' own bookkeeping. The reset wipes content, not the migration state —
  # emptying these would leave the app looking un-migrated.
  RETAINED_TABLES = %w[ar_internal_metadata schema_migrations].freeze

  # On the read floor deliberately: refused during maintenance, Cerberus could
  # never see the flag it is meant to be honouring.
  def show
    authorize! :read, :maintenance

    @maintenance = MaintenanceMode.current
    render 'maintenance/show'
  end

  # The one action that stays reachable while the window is OPEN (see
  # #read_only_exempt?), or the window could never be closed.
  def update
    authorize! :maintain, :maintenance

    read_only = ActiveModel::Type::Boolean.new.cast(params[:read_only])
    return render_error(:bad_request, 'read_only is required') if read_only.nil?

    # An unnamed door is a human; the deploy orchestrator names itself.
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

    delete_all_rows!

    # SolrCore.url, not a literal: reset must wipe the core the composite
    # persister writes to, and in test that core is env-driven per instance.
    c = RSolr.connect(url: SolrCore.url)

    c.delete_by_query '*:*'
    c.commit

    # NOT optional: the DB wipe resets the NOID minter, so reminted ids
    # resolve to the SAME OCFL objects as prior runs. OCFL state is
    # cumulative, so each run would stack onto the last and pollute a
    # resource's history with other resources' content.
    purge_storage!
    seed_fixture_users!
  end

  private

    # NOT database_cleaner: reset is reachable in staging, and that gem sits
    # in the :development, :test bundle group, so the constant is undefined
    # there.
    #
    # DELETE rather than TRUNCATE, integrity disabled, so the wipe is
    # order-independent across foreign keys.
    def delete_all_rows!
      # Independent of the caller's guard on purpose: this must never be
      # reachable outside a resettable env even if a caller forgets to check.
      raise "refusing to wipe the database outside a resettable env (#{Rails.env})" unless resettable_env?

      conn   = ActiveRecord::Base.connection
      tables = conn.tables - RETAINED_TABLES

      conn.disable_referential_integrity do
        tables.each { |table| conn.execute("DELETE FROM #{conn.quote_table_name(table)}") }
      end
    end

    def refuse_during_maintenance
      raise Exceptions::ReadOnlyMode if MaintenanceMode.read_only?
    end

    # The SOLE exemption from the maintenance floor. Without it an open window
    # would refuse the very request that closes it.
    def read_only_exempt?
      action_name == 'update'
    end

    # :system-gated, so without this the ledger would record the system
    # principal flipping the flag and not who asked. Mirrors
    # Users::TokensController#audit_token_event.
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
      # No Grouper groups, not an owner of the seed tree: isolates the
      # standard-vs-staff boundary.
      create_fixture_user(name: 'User, Standard', nuid: '000000005',
                          email: 'standard@northeastern.edu', role: :standard,
                          groups: ['northeastern:drs:library:dsg_students'])
      create_fixture_user(name: 'User, Standard', nuid: '000000005',
                          email: 'standard@husky.neu.edu', role: :standard,
                          groups: ['northeastern:drs:all'])
      create_fixture_user(name: 'Doe, Jane', nuid: '000000002', role: :privileged,
                          email: 'dps@northeastern.edu',
                          groups: ['northeastern:drs:repository:staff',
                                   'northeastern:drs:repository:api',
                                   'northeastern:drs:repository:admin'])
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

    # Children are removed rather than the root, which is a container mount
    # point, so the adapter's path stays valid for the re-seed.
    def purge_storage!
      # Independent of the caller's guard, because this rm_rf targets the
      # preservation root — never let it be reachable outside a resettable env.
      raise "refusing to purge OCFL storage outside a resettable env (#{Rails.env})" unless resettable_env?

      # An absent root means nothing to purge -- the adapter creates it lazily,
      # so test's ephemeral tmp/files may not exist yet. The guard runs PER
      # root: one misconfigured entry must not be reached through a sibling.
      Valkyrie.config.storage_adapter.storage_roots.each_value do |storage_root|
        root = storage_root.base_path
        FileUtils.mkdir_p(root)
        guard_storage_root!(root)
        FileUtils.rm_rf(root.children)
      end
    end

    # The real roots are absolute and several segments deep, so fewer than two
    # segments signals a misconfiguration this must not rm_rf against.
    def guard_storage_root!(root)
      raise "storage root missing or not a directory: #{root.inspect}" unless root && File.directory?(root)
      raise "refusing to purge unsafe storage root: #{root.inspect}" if root.cleanpath.each_filename.to_a.length < 2
    end
end
