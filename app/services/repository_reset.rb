# frozen_string_literal: true

# Wipes a development, staging or test repository back to its fixtures, for
# GET /reset and `rake reset:clean` alike. Every step is mandatory; see
# docs/availability.md for why.
class RepositoryReset < ApplicationService
  # Production is never wiped.
  RESETTABLE_ENVS = %w[development staging test].freeze

  # Rails' own bookkeeping. The reset wipes content, not the migration state —
  # emptying these would leave the app looking un-migrated.
  RETAINED_TABLES = %w[ar_internal_metadata schema_migrations].freeze

  def call
    raise "Wrong env - #{Rails.env} - must not be production" unless resettable_env?
    # A caller that skips authorize! never meets the maintenance floor, so the
    # most destructive write Atlas has checks it here, for every caller.
    raise Exceptions::ReadOnlyMode if MaintenanceMode.read_only?

    delete_all_rows!
    wipe_index!
    purge_storage!
    ResponseCache.clear!
    seed_fixture_users!
  end

  private

    def resettable_env?
      RESETTABLE_ENVS.include?(Rails.env.to_s)
    end

    # NOT database_cleaner: reset is reachable in staging, and that gem sits
    # in the :development, :test bundle group, so the constant is undefined
    # there.
    #
    # DELETE rather than TRUNCATE, integrity disabled, so the wipe is
    # order-independent across foreign keys.
    def delete_all_rows!
      # Independent of #call's guard on purpose: this must never be reachable
      # outside a resettable env even if a caller forgets to check.
      raise "refusing to wipe the database outside a resettable env (#{Rails.env})" unless resettable_env?

      conn   = ActiveRecord::Base.connection
      tables = conn.tables - RETAINED_TABLES

      conn.disable_referential_integrity do
        tables.each { |table| conn.execute("DELETE FROM #{conn.quote_table_name(table)}") }
      end
    end

    # SolrCore.url, not a literal: the reset must wipe the core the composite
    # persister writes to, and in test that core is env-driven per instance.
    def wipe_index!
      connection = RSolr.connect(url: SolrCore.url)
      connection.delete_by_query '*:*'
      connection.commit
    end

    # Children are removed rather than the root, which is a container mount
    # point, so the adapter's path stays valid for the re-seed.
    def purge_storage!
      # Independent of #call's guard, because this rm_rf targets the
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

    def seed_fixture_users!
      # non-human fixtures — single-row each by design
      create_fixture_user(name: 'User, System', nuid: '000000000',
                          email: 'admin@northeastern.edu', role: :system)
      create_fixture_user(name: 'User, Anonymous', nuid: '000000099',
                          email: 'anonymous@northeastern.edu', role: :anonymous)
      # The rolling fixity checker authenticates as this; without it every sweep
      # after a reset answers 400 until someone recreates it.
      create_fixture_user(name: 'User, Fixity Checker', nuid: User::FIXITY_CHECKER_NUID,
                          email: 'fixity-checker@northeastern.edu', role: :fixity_checker)

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
                          groups: ['northeastern:drs:repository:admin', 'northeastern:drs:repository:api'])
    end

    def create_fixture_user(**attrs)
      User.create(password: Devise.friendly_token[0, 20], **attrs)
    end
end
