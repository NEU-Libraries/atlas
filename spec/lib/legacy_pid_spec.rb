# frozen_string_literal: true

require 'rails_helper'

# The pid rules every creator shares through LegacyPid.claim. See
# docs/legacy-pids.md.
RSpec.describe LegacyPid do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  def solr_doc(resource)
    Atlas.index_adapter.connection.get('select', params: { q: %(id:"#{resource.id}"), fl: 'legacy_pid_ssi' })
         .dig('response', 'docs', 0)
  end

  def refusal(&)
    error = nil
    begin
      yield
    rescue Exceptions::LegacyPidError => e
      error = e
    end
    error
  end

  describe 'a create that brings a pid' do
    {
      'Community'  => ->(_, pid) { CommunityCreator.call(legacy_pid: pid) },
      'Collection' => ->(spec, pid) { CollectionCreator.call(parent_id: spec.community.noid, legacy_pid: pid) },
      'Work'       => ->(spec, pid) { WorkCreator.call(parent_id: spec.collection.noid, legacy_pid: pid) }
    }.each do |type, create|
      it "records it on a #{type} in Postgres, Solr and the envelope" do
        resource = create.call(self, 'neu:1234')

        expect(Resource.find(resource.noid).legacy_pid).to eq('neu:1234')
        expect(solr_doc(resource)).to eq('legacy_pid_ssi' => 'neu:1234')
        expect(on_disk_envelope(resource)).to include('legacy_pid' => 'neu:1234')
      end
    end

    it 'records nothing when no pid is sent' do
      work = WorkCreator.call(parent_id: collection.noid)

      expect(work.legacy_pid).to be_nil
      expect(on_disk_envelope(work)).to include('legacy_pid' => nil)
    end
  end

  describe 'the refusals' do
    %w[1234 neu: neu:a/b neu:a.b neu:a?b NEU:1234 hdl:1234].push('', ' neu:1').each do |bad|
      it "refuses #{bad.inspect} as invalid_legacy_pid, creating nothing" do
        error = nil
        expect { error = refusal { CommunityCreator.call(legacy_pid: bad) } }
          .not_to(change { Atlas.query.count_all_of_model(model: Community) })

        expect(error).to have_attributes(code: :invalid_legacy_pid, status: :unprocessable_content, holder_id: nil)
      end
    end

    # The pid is unique across types, so a Work cannot take a Community's.
    it 'refuses a pid another type holds, naming the holder' do
      holder = CommunityCreator.call(legacy_pid: 'neu:7')

      error = refusal { WorkCreator.call(parent_id: collection.noid, legacy_pid: 'neu:7') }

      expect(error).to have_attributes(code: :legacy_pid_taken, status: :conflict, holder_id: holder.noid)
      expect(error.message).to eq("Community #{holder.noid} already holds neu:7")
      expect(collection.children.grep(Work)).to be_empty
    end

    it 'refuses a pid a tombstoned resource holds' do
      holder = CollectionCreator.call(parent_id: community.noid, legacy_pid: 'neu:8')
      holder.tombstone(by: '000000004')
      Atlas.persister.save(resource: holder)

      error = refusal { CollectionCreator.call(parent_id: community.noid, legacy_pid: 'neu:8') }

      expect(error).to have_attributes(code: :legacy_pid_taken, holder_id: holder.noid)
    end

    it 'checks the pid before the handle, and refuses with nothing created' do
      CommunityCreator.call(legacy_pid: 'neu:9')

      error = refusal do
        WorkCreator.call(parent_id: collection.noid, legacy_pid: 'neu:9', handle: 'not a handle')
      end

      expect(error.code).to eq(:legacy_pid_taken)
    end

    it 'releases the advisory lock after a create and after a refusal' do
      CommunityCreator.call(legacy_pid: 'neu:10')
      refusal { CommunityCreator.call(legacy_pid: 'neu:10') }
      held = ActiveRecord::Base.connection.select_value(
        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()"
      )

      expect(held).to eq(0)
    end
  end

  # Transactional tests pin one connection that every thread shares, and a
  # session advisory lock is re-entrant within one session, so this group turns
  # them off to give each thread its own connection, as Puma threads have. The
  # slowed holder check widens the race: without the lock both creates pass it.
  describe 'two concurrent creates with the same pid' do
    self.use_transactional_tests = false

    # These creates commit, so the rows a wipe! leaves behind outlive the
    # example. A ledger row naming an object a later example removes reads as
    # stale to StorageFootprintRebuilder.
    after do
      Atlas.persister.wipe!
      StorageFootprint.delete_all
      Metadata::MODS.delete_all
    end

    it 'lets exactly one take it, and tells the other who did' do
      allow(described_class).to receive(:holder).and_wrap_original do |original, pid|
        original.call(pid).tap { sleep 0.5 }
      end

      outcomes = Array.new(2) do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            CommunityCreator.call(legacy_pid: 'neu:race').noid
          rescue Exceptions::LegacyPidError => e
            e
          end
        end
      end.map(&:value)

      created, refused = outcomes.partition { |outcome| outcome.is_a?(String) }
      expect(created.size).to eq(1)
      expect(refused.map(&:holder_id)).to eq(created)
    end
  end

  describe '.holder' do
    it 'finds the holder of any type, and nil for a free pid' do
      work = WorkCreator.call(parent_id: collection.noid, legacy_pid: 'neu:11')

      expect(described_class.holder('neu:11')).to have_attributes(class: Work, noid: work.noid)
      expect(described_class.holder('neu:12')).to be_nil
    end
  end
end
