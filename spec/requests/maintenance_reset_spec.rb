# frozen_string_literal: true

require 'rails_helper'

# Safety coverage for MaintenanceController#reset's on-disk storage purge.
# The rswag doc spec (spec/requests/maintenance_spec.rb) covers the 204
# contract.
#
# Why the purge matters: the DB wipe resets the NOID minter, so the next seed
# re-mints the same NOID sequence; without purging storage those reminted ids
# resolve to prior runs' OCFL objects and stack new content onto old, polluting
# a resource's MODS history with other resources' content across reset runs.
#
# These specs deliberately do NOT drive the full reset action against the real
# storage adapter: that would wipe the suite's shared tmp/files OCFL store
# mid-run. Instead the destructive purge is exercised against an isolated
# throwaway root, the DB wipe is exercised on its own inside the example's
# fixture transaction (so it rolls back), and the action-level env guard is
# asserted via the HTTP path where it raises before touching anything.
RSpec.describe MaintenanceController do
  subject(:controller) { described_class.new }

  describe '#purge_storage! (the rm_rf)' do
    # Point the storage adapter at a throwaway root so the destructive purge
    # never touches the suite's shared tmp/files store. Stubs live in `before`
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

      controller.send(:purge_storage!)

      expect(@root.children).to be_empty
      expect(@root).to be_directory
    end

    it 'refuses to purge — leaving files intact — outside a resettable env' do
      @root.join('precious').write('keep me')
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))

      expect { controller.send(:purge_storage!) }.to raise_error(/resettable env/)
      expect(@root.children).not_to be_empty
    end

    # Regression: test's tmp/files is ephemeral and absent on a fresh container;
    # the OCFL adapter would lazily create it on first write, but the purge runs
    # before any write. An absent root must mean "nothing to purge", not a fatal
    # error that aborts /reset and breaks the suite.
    it 'tolerates an absent root, creating an empty one for the re-seed' do
      absent       = @root.join('not-yet-created')
      fake_root    = instance_double(Valkyrie::Storage::OCFL::StorageRoot, base_path: absent)
      fake_adapter = instance_double(Valkyrie::Storage::OCFL, storage_roots: { 'r001' => fake_root })
      allow(Valkyrie.config).to receive(:storage_adapter).and_return(fake_adapter)
      expect(absent).not_to exist

      expect { controller.send(:purge_storage!) }.not_to raise_error

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

      expect { controller.send(:delete_all_rows!) }.to change(User, :count).to(0)
    end

    # Regression: reset must not depend on database_cleaner, which is absent
    # from the staging bundle. The replacement has to keep its two guarantees.
    it "keeps Rails' bookkeeping tables so the app stays migrated" do
      controller.send(:delete_all_rows!)

      described_class::RETAINED_TABLES.each do |table|
        count = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{table}")
        expect(count).to be_positive, "expected #{table} to survive the wipe"
      end
    end

    it 'refuses to wipe — leaving rows intact — outside a resettable env' do
      User.create!(email: 'keep-me@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000009004', name: 'User, Spared', role: :guest)
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))

      expect { controller.send(:delete_all_rows!) }.to raise_error(/resettable env/)
      expect(User.count).to be_positive
    end

    it 'deletes across a foreign key regardless of table order' do
      user = User.create!(email: 'parent@example.invalid', password: SecureRandom.hex(16),
                          nuid: '000009002', name: 'User, Parent', role: :guest)
      IdempotencyKey.create!(user: user, key: 'k-1', resource_type: 'Work', resource_noid: 'neu:abc123')

      expect { controller.send(:delete_all_rows!) }.not_to raise_error
      expect(IdempotencyKey.count).to eq(0)
    end
  end

  describe '#guard_storage_root! (refuses a dangerous target)' do
    it 'rejects a dangerously shallow root (e.g. a single-segment path)' do
      expect { controller.send(:guard_storage_root!, Pathname.new('/tmp')) }
        .to raise_error(/unsafe storage root/)
    end

    it 'rejects a missing / non-directory root' do
      expect { controller.send(:guard_storage_root!, Pathname.new('/no/such/dir/anywhere')) }
        .to raise_error(/missing or not a directory/)
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
