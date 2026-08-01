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

  # Reset is restricted to ephemeral environments; production is never wiped.
  RESETTABLE_ENVS = %w[development staging test].freeze

  def reset
    raise "Wrong env - #{Rails.env} - must not be production" unless resettable_env?

    DatabaseCleaner.strategy = :deletion
    DatabaseCleaner.clean

    c = if Rails.env.test?
          RSolr.connect(url: 'http://solr:8983/solr/blacklight-test')
        else
          RSolr.connect(url: 'http://solr:8983/solr/blacklight-core')
        end

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

    # Empty the on-disk Valkyrie (OCFL) storage root, leaving the root directory
    # itself in place (it is a container mount point). Children are removed
    # rather than the root so the adapter's path stays valid for the re-seed.
    def purge_storage!
      # Independent of the caller's guard, because this rm_rf targets the
      # preservation root — never let it be reachable outside a resettable env.
      raise "refusing to purge OCFL storage outside a resettable env (#{Rails.env})" unless resettable_env?

      root = Valkyrie.config.storage_adapter.storage_root.base_path
      # An absent root just means "nothing to purge" — the OCFL adapter lazily
      # creates it on first write, so test's ephemeral tmp/files may not exist
      # yet on a freshly booted container. Create it so the guard's directory
      # check passes and the re-seed has a valid empty store; no-op when the root
      # already exists (dev/staging's mounted volume), so their behavior is
      # unchanged. The shallow-/unsafe-root guard below still protects against /.
      FileUtils.mkdir_p(root)
      guard_storage_root!(root)
      FileUtils.rm_rf(root.children)
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
