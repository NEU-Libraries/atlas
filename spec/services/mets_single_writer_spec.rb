# frozen_string_literal: true

require 'rails_helper'

# Rebuilds of one owner's METS run one at a time under its advisory lock. See
# docs/write-safety.md.
#
# Transactional tests pin one connection that every thread shares, and a
# session advisory lock is re-entrant within one session, so this file turns
# them off to give each thread its own connection, as Puma threads have. A
# slowed build widens the race: without the lock both rebuilds read the same
# state, both write an OCFL version, and the second Blob save raises.
RSpec.describe 'METS rebuilds of one owner' do
  self.use_transactional_tests = false

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:uploads)    { Concurrent::AtomicFixnum.new }

  def fixture(name) = Rails.root.join('spec/fixtures/files', name).to_s

  def page(position)
    FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: position)
  end

  def in_threads(*blocks)
    blocks.map do |block|
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { block.call } }
    end.map(&:value)
  end

  def slowed(rebuilder, build)
    allow(rebuilder).to receive(build).and_wrap_original do |original, *args, **kw|
      original.call(*args, **kw).tap { sleep 0.5 }
    end
    rebuilder
  end

  def mets_pages = Metadata::METS.find_by(valkyrie_id: work.noid).pages.map(&:noid)

  def advisory_locks_held
    ActiveRecord::Base.connection.select_value(
      "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()"
    )
  end

  before do
    work
    allow(StaleRetry).to receive(:pause)
    allow(Valkyrie.config.storage_adapter).to receive(:upload).and_wrap_original do |original, **kw|
      uploads.increment if kw[:original_filename] == 'mets.xml'
      original.call(**kw)
    end
  end

  # These writes commit, so the rows a wipe! leaves behind outlive the example.
  after do
    Atlas.persister.wipe!
    StorageFootprint.delete_all
    Metadata::MODS.delete_all
    Metadata::METS.delete_all
  end

  describe 'two rebuilds of one Work at once' do
    it 'write one OCFL version that lists every page, and neither loses a lock race' do
      pages = [page(1), page(2), page(3)]
      uploads.value = 0
      rebuilders = Array.new(2) { slowed(WorkMETSRebuilder.new(work: work), :mets_for_work) }

      in_threads(*rebuilders.map { |rebuilder| -> { rebuilder.call } })

      expect(StaleRetry).not_to have_received(:pause)
      expect(uploads.value).to eq(1)
      expect(Work.find(work.noid).mets_blob.file_identifiers.length).to eq(1)
      expect(mets_pages).to eq(pages.map(&:noid))
    end
  end

  describe '/complete racing a page added to the Work' do
    it 'lists the new page in the METS, and neither loses a lock race' do
      first = page(1)
      # The first build mints NOIDs, and the test minter is not thread-safe.
      WorkMETSRebuilder.call(work: work)
      completed = Atlas.persister.save(resource: Work.find(work.noid).tap { |w| w.in_progress = false })
      rebuilder = slowed(WorkMETSRebuilder.new(work: completed), :mets_for_work)

      _, added = in_threads(
        -> { rebuilder.call },
        -> { sleep(0.1).then { page(2) } }
      )

      expect(StaleRetry).not_to have_received(:pause)
      expect(mets_pages).to eq([first.noid, added.noid])
    end
  end

  describe 'two rebuilds of one FileSet at once' do
    it 'write one OCFL version that lists both Blobs, and neither loses a lock race' do
      allow(METSRebuilder).to receive(:call)
      file_set = FileSetCreator.call(work_id: work.noid, classification: Classification.text)
      2.times { |i| BlobCreator.call(path: fixture('example.pdf'), file_set_id: file_set.id, original_filename: "#{i}.pdf") }
      allow(METSRebuilder).to receive(:call).and_call_original
      uploads.value = 0
      rebuilders = Array.new(2) { slowed(METSRebuilder.new(file_set: file_set), :mets_for) }

      in_threads(*rebuilders.map { |rebuilder| -> { rebuilder.call } })

      expect(StaleRetry).not_to have_received(:pause)
      expect(uploads.value).to eq(1)
      expect(FileSet.find(file_set.id).mets_xml).to include(*FileSet.find(file_set.id).content_files.map(&:noid))
    end
  end

  describe 'a rebuild that makes the first METS Blob' do
    it 'takes the first-build lock again inside its own, and releases both' do
      page(1)

      WorkMETSRebuilder.call(work: work)

      expect(Work.find(work.noid).mets_blob).to be_present
      expect(advisory_locks_held).to eq(0)
    end
  end
end
