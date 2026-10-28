# frozen_string_literal: true

require 'rails_helper'

# Safety coverage for RepositoryReset, which GET /reset and `rake reset:clean`
# both run. The rswag doc spec (spec/requests/maintenance_spec.rb) covers the
# route's 204 contract.
#
# Why the purge matters: the DB wipe resets the NOID minter, so the next seed
# re-mints the same NOID sequence; without purging storage those reminted ids
# resolve to prior runs' OCFL objects and stack new content onto old, polluting
# a resource's MODS history with other resources' content across reset runs.
#
# These specs deliberately do NOT drive the full reset action against the real
# storage adapter: that would wipe the run's own OCFL store
# mid-run. Instead the destructive purge is exercised against an isolated
# throwaway root, the DB wipe is exercised on its own inside the example's
# fixture transaction (so it rolls back), and the action-level env guard is
# asserted via the HTTP path where it raises before touching anything.
RSpec.describe RepositoryReset do
  subject(:reset) { described_class.new }

  describe '#purge_storage! (the rm_rf)' do
    # Point the storage adapter at a throwaway root so the destructive purge
    # never touches the run's own store. Stubs live in `before`
    # (not `around`) so they run inside RSpec's per-example mock scope.
    before do
      @root        = Pathname.new(Dir.mktmpdir)
      fake_root    = instance_double(Valkyrie::Storage::OCFL::StorageRoot, base_path: @root)
      fake_adapter = instance_double(Valkyrie::Storage::OCFL, storage_roots: { 'r001' => fake_root })
      allow(Valkyrie.config).to receive(:storage_adapter).and_return(fake_adapter)
    end

    after { FileUtils.rm_rf(@root) if @root }

    it 'empties the storage root, preserving the root directory itself (mount point)' do
      object = @root.join('prior-run-object')
      object.mkpath
      object.join('descMetadata.xml').write('<mods/>')

      reset.send(:purge_storage!)

      expect(@root.children).to be_empty
      expect(@root).to be_directory
    end

    it 'refuses to purge — leaving files intact — outside a resettable env' do
      @root.join('precious').write('keep me')
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))

      expect { reset.send(:purge_storage!) }.to raise_error(/resettable env/)
      expect(@root.children).not_to be_empty
    end

    # Regression: the test storage root is ephemeral and absent on a fresh container;
    # the OCFL adapter would lazily create it on first write, but the purge runs
    # before any write. An absent root must mean "nothing to purge", not a fatal
    # error that aborts /reset and breaks the suite.
    it 'tolerates an absent root, creating an empty one for the re-seed' do
      absent       = @root.join('not-yet-created')
      fake_root    = instance_double(Valkyrie::Storage::OCFL::StorageRoot, base_path: absent)
      fake_adapter = instance_double(Valkyrie::Storage::OCFL, storage_roots: { 'r001' => fake_root })
      allow(Valkyrie.config).to receive(:storage_adapter).and_return(fake_adapter)
      expect(absent).not_to exist

      expect { reset.send(:purge_storage!) }.not_to raise_error

      expect(absent).to be_directory
      expect(absent.children).to be_empty
    end
  end

  # The wipe runs inside the example's fixture transaction, so every DELETE here
  # rolls back and the suite's own rows survive.
  describe '#delete_all_rows! (the DB wipe)' do
    it 'empties the application tables' do
      User.create!(email: 'wipe-me@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000009001', name: 'User, Doomed', role: :guest)

      expect { reset.send(:delete_all_rows!) }.to change(User, :count).to(0)
    end

    # Regression: reset must not depend on database_cleaner, which is absent
    # from the staging bundle. The replacement has to keep its two guarantees.
    it "keeps Rails' bookkeeping tables so the app stays migrated" do
      reset.send(:delete_all_rows!)

      described_class::RETAINED_TABLES.each do |table|
        count = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{table}")
        expect(count).to be_positive, "expected #{table} to survive the wipe"
      end
    end

    it 'refuses to wipe — leaving rows intact — outside a resettable env' do
      User.create!(email: 'keep-me@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000009004', name: 'User, Spared', role: :guest)
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))

      expect { reset.send(:delete_all_rows!) }.to raise_error(/resettable env/)
      expect(User.count).to be_positive
    end

    it 'deletes across a foreign key regardless of table order' do
      user = User.create!(email: 'parent@example.invalid', password: SecureRandom.hex(16),
                          nuid: '000009002', name: 'User, Parent', role: :guest)
      IdempotencyKey.create!(user: user, key: 'k-1', resource_type: 'Work', resource_noid: 'neu:abc123')

      expect { reset.send(:delete_all_rows!) }.not_to raise_error
      expect(IdempotencyKey.count).to eq(0)
    end
  end

  describe '#guard_storage_root! (refuses a dangerous target)' do
    it 'rejects a dangerously shallow root (e.g. a single-segment path)' do
      expect { reset.send(:guard_storage_root!, Pathname.new('/tmp')) }
        .to raise_error(/unsafe storage root/)
    end

    it 'rejects a missing / non-directory root' do
      expect { reset.send(:guard_storage_root!, Pathname.new('/no/such/dir/anywhere')) }
        .to raise_error(/missing or not a directory/)
    end
  end

  # The destructive steps are stubbed so the action runs without wiping the
  # suite's own rows, Solr core or storage; only the cache clear is real.
  describe '#call (the response cache)', :response_cache do
    before do
      allow(reset).to receive(:delete_all_rows!)
      allow(reset).to receive(:purge_storage!)
      allow(reset).to receive(:seed_fixture_users!)
      allow(RSolr).to receive(:connect).and_return(instance_double(RSolr::Client, delete_by_query: nil, commit: nil))
    end

    it "drops the prior run's cached bodies, so a reminted NOID misses" do
      ResponseCache.write(scope: 'resources.permissions', noid: 'reused', status: 200, body: '{}',
                          content_type: 'application/json')

      reset.call

      expect(ResponseCache.read(scope: 'resources.permissions', noid: 'reused')).to be_nil
    end
  end

  # The destructive steps are stubbed; the order and the guards are what is
  # under test.
  describe '#call' do
    let(:solr) { instance_double(RSolr::Client, delete_by_query: nil, commit: nil) }

    before do
      %i[delete_all_rows! purge_storage! seed_fixture_users!].each { |step| allow(reset).to receive(step) }
      allow(RSolr).to receive(:connect).and_return(solr)
    end

    it 'wipes the rows, the index and the storage before it re-seeds' do
      reset.call

      expect(reset).to have_received(:delete_all_rows!).ordered
      expect(solr).to have_received(:delete_by_query).with('*:*').ordered
      expect(reset).to have_received(:purge_storage!).ordered
      expect(reset).to have_received(:seed_fixture_users!).ordered
    end

    it 'wipes the core the persister writes to, not a fixed URL' do
      reset.call
      expect(RSolr).to have_received(:connect).with(url: SolrCore.url)
    end

    # The route used to hold this check; the rake task must meet it too.
    it 'refuses during a maintenance window, before touching anything' do
      allow(MaintenanceMode).to receive(:read_only?).and_return(true)

      expect { reset.call }.to raise_error(Exceptions::ReadOnlyMode)
      expect(reset).not_to have_received(:delete_all_rows!)
    end

    it 'refuses outside a resettable env, before touching anything' do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))

      expect { reset.call }.to raise_error(/must not be production/)
      expect(reset).not_to have_received(:delete_all_rows!)
    end
  end

  # The real wipe, as the suite's GET /reset example already runs it: the table
  # deletes roll back with the example, and the storage purge reaches only this
  # worker's own root.
  describe '#call against the real stores' do
    after { Atlas.persister.wipe! }

    it 'leaves no OCFL object behind for a reminted NOID to land on' do
      work = WorkCreator.call(parent_id: CollectionCreator.call(parent_id: CommunityCreator.call.noid).noid)
      object = Valkyrie.config.storage_adapter.storage_roots.values.first.object_root_for(work.noid)
      expect(object).to exist

      described_class.call

      expect(object).not_to exist
      expect(Valkyrie.config.storage_adapter.object_versions(key: work.noid)).to be_nil
    end
  end

  # Inside the example's fixture transaction, so the seeded rows roll back.
  describe '#seed_fixture_users!' do
    it 'seeds the fixity checker, so a sweep still authenticates after a reset' do
      reset.send(:delete_all_rows!)
      reset.send(:seed_fixture_users!)

      expect(User.find_by(nuid: User::FIXITY_CHECKER_NUID)&.role).to eq('fixity_checker')
      expect(User.where(role: %i[system anonymous fixity_checker]).count).to eq(3)
    end
  end
end

# The reset endpoint is an unauthenticated GET; its only gate against running in
# production is the env guard. Assert it fires at the HTTP boundary. This raises
# before any DB/Solr/storage mutation, so it does not pollute the suite's shared
# storage.
RSpec.describe 'GET /reset env guard', type: :request do
  it 'refuses to run in production' do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))

    expect { get '/reset' }.to raise_error(/must not be production/)
  end
end
