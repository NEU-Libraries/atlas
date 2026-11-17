# frozen_string_literal: true

require 'rails_helper'

# Each group is one way a write could answer an error after part of it had
# landed, when a concurrent writer moved a lock token in between. See
# docs/write-safety.md.
RSpec.describe 'Writes that lose an optimistic-lock race' do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  def fixture(name) = Rails.root.join('spec/fixtures/files', name).to_s

  # Raises StaleObjectError for the first `times` saves the block matches, as a
  # concurrent writer would, without letting those saves through.
  def lose_saves(times, &matches)
    lost = 0
    allow(Atlas.persister).to receive(:save).and_wrap_original do |original, resource:, **rest|
      if lost < times && matches.call(resource)
        lost += 1
        raise Valkyrie::Persistence::StaleObjectError, resource.id.to_s
      end

      original.call(resource: resource, **rest)
    end
  end

  def persisted_file_set?(resource) = resource.is_a?(FileSet) && resource.persisted?

  before do
    work
    allow(StaleRetry).to receive(:pause)
  end

  describe 'an upload whose METS rebuild keeps losing' do
    before { allow(METSRebuilder).to receive(:call).and_raise(Valkyrie::Persistence::StaleObjectError) }

    it 'keeps the new Blob and answers it, because the METS is derived' do
      blob = BlobCreator.call(path: fixture('example.pdf'), work_id: work.noid, original_filename: 'a.pdf')

      expect(Blob.find(blob.id).file_identifiers).not_to be_empty
      expect(blob.parent.member_ids).to include(blob.id)
    end

    it 'keeps a new revision and answers it' do
      blob = BlobCreator.call(path: fixture('example.pdf'), work_id: work.noid, original_filename: 'a.pdf')

      saved, version_id = BlobRevisionAppender.call(blob: Blob.find(blob.id), source_path: fixture('example.pdf'),
                                                    name: 'b.pdf')

      expect(saved.file_identifiers.last).to eq(version_id)
    end
  end

  describe 'an upload whose attach to the FileSet loses once' do
    it 'reloads the FileSet and attaches the Blob' do
      file_set = FileSetCreator.call(work_id: work.noid, classification: Classification.text)
      lose_saves(1) { |resource| persisted_file_set?(resource) && resource.id == file_set.id }

      blob = BlobCreator.call(path: fixture('example.pdf'), file_set_id: file_set.id, original_filename: 'a.pdf')

      expect(FileSet.find(file_set.id).member_ids).to include(blob.id)
    end
  end

  describe 'a revision whose reclassification loses once' do
    it 'reloads the FileSet and moves its type' do
      blob = BlobCreator.call(path: fixture('example.png'), work_id: work.noid, original_filename: 'a.png')
      lose_saves(1) { |resource| persisted_file_set?(resource) && resource.id == blob.parent.id }

      BlobRevisionAppender.call(blob: Blob.find(blob.id), source_path: fixture('example.pdf'), name: 'scan.pdf')

      expect(FileSet.find(blob.parent.id).type).to eq(Classification.text.name)
    end
  end

  describe 'a handle mint whose writes lose once' do
    let(:client) do
      instance_double(HandleClient, configured?: true).tap do |double|
        allow(double).to receive(:mint) { |suffix, **| "DRSDEV/#{suffix}" }
      end
    end

    def mint = HandleMinter.call(work: work, client: client, public_base: 'https://repository.example.edu')

    # The handle server holds the handle by the time the Work save runs.
    it 'records the registered handle on the Work, without registering it twice' do
      lose_saves(1) { |resource| resource.is_a?(Work) && resource.handle.present? }

      mint

      expect(Work.find(work.noid).handle).to eq("DRSDEV/#{work.noid}")
      expect(client).to have_received(:mint).once
    end

    it 'records the handle in the MODS when that write loses once' do
      mods_blob_id = work.mods_blob.id
      lose_saves(1) { |resource| resource.is_a?(Blob) && resource.id == mods_blob_id }

      mint

      expect(Work.find(work.noid).mods_xml).to include("hdl.handle.net/DRSDEV/#{work.noid}")
    end
  end

  describe 'a purge whose detach from a linking Work loses once' do
    it 'reloads the Work, drops the link and finishes the purge' do
      target = CollectionCreator.call(parent_id: community.noid)
      LinkedMemberCreator.call(work: Work.find(work.noid), collection: target)
      lose_saves(1) { |resource| resource.is_a?(Work) && resource.id == work.id }

      ResourcePurger.call(resource: Collection.find(target.noid))

      expect(Collection.find(target.noid)).to be_nil
      expect(Array(Work.find(work.noid).a_linked_member_of)).to be_empty
    end
  end

  describe 'a Delegate create whose attach loses once' do
    it 'attaches the one Delegate it saved, leaving none behind' do
      DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name, uri: 'https://iiif.example/a.jpg')
      derivative = Work.find(work.noid).children.find { |c| c.is_a?(FileSet) && c.type == Classification.derivative.name }
      lose_saves(1) { |resource| persisted_file_set?(resource) && resource.id == derivative.id }

      DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image_2x.name, uri: 'https://iiif.example/b.jpg')

      members = Atlas.query.find_members(resource: FileSet.find(derivative.id)).grep(Delegate)
      expect(members.map(&:use)).to contain_exactly(Role.thumbnail_image.name, Role.thumbnail_image_2x.name)
      expect(Atlas.query.find_all_of_model(model: Delegate).count).to eq(2)
    end
  end

  describe 'a page added to a completed Work whose METS rebuild keeps losing' do
    it 'keeps the page, because the METS is derived' do
      completed = Work.find(work.noid)
      completed.in_progress = false
      Atlas.persister.save(resource: completed)
      allow(WorkMETSRebuilder).to receive(:call).and_raise(Valkyrie::Persistence::StaleObjectError)

      page = FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: 1)

      expect(FileSet.find(page.id)).to be_present
    end
  end

  # Runs a competing first build inside the lock window, after this build saw
  # no Blob and before it takes the lock, as a concurrent request would. A
  # rebuild holds the same lock around its first build, so `at` names which
  # hold of the scope is the first build's.
  def race_first_build(scope, at: 1)
    holds = 0
    allow(AdvisoryLock).to receive(:hold).and_wrap_original do |original, lock_scope, id, &block|
      holds += 1 if lock_scope == scope
      yield if lock_scope == scope && holds == at
      original.call(lock_scope, id, &block)
    end
  end

  def file_sets_of(type) = Work.find(work.noid).children.select { |c| c.is_a?(FileSet) && c.type == type }

  describe "two first builds of a Work's METS" do
    it 'make one structural FileSet, because the second takes the Blob the first made' do
      FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: 1)
      race_first_build('work_mets', at: 2) { WorkMETSRebuilder.call(work: work) }

      WorkMETSRebuilder.call(work: work)

      structural = file_sets_of(Classification.structural_metadata.name)
      expect(structural.length).to eq(1)
      expect(structural.first.files.compact.count { |b| b.use == Role.structural_metadata.name }).to eq(1)
      expect(Metadata::METS.find_by(valkyrie_id: work.noid).pages.length).to eq(1)
    end
  end

  describe 'a first METS build on a FileSet whose attach loses once' do
    it 'attaches the one METS Blob' do
      bare = Atlas.persister.save(resource: FileSet.new(type: Classification.text.name, a_member_of: work.id))
      lose_saves(1) { |resource| persisted_file_set?(resource) && resource.id == bare.id }

      bare.mets_xml = bare.mets_template

      metadata = FileSet.find(bare.id).files.compact.select { |b| b.use == Role.structural_metadata.name }
      expect(metadata.length).to eq(1)
    end
  end

  describe 'Darwin Core uploads that race' do
    let(:dwc) { File.read(fixture('dwc.xml')) }

    it 'make one Darwin Core FileSet across two first builds' do
      race_first_build('darwin_core') { Work.find(work.noid).darwin_core_xml = dwc }

      Work.find(work.noid).darwin_core_xml = dwc

      records = file_sets_of(Classification.darwin_core.name)
      expect(records.length).to eq(1)
      expect(records.first.files.compact.count { |b| b.use == Role.darwin_core.name }).to eq(1)
    end

    it 'restores a tombstoned record when the restore loses once' do
      Work.find(work.noid).darwin_core_xml = dwc
      Work.find(work.noid).tombstone_darwin_core!(by: '000000004')
      record_set = file_sets_of(Classification.darwin_core.name).first
      lose_saves(1) { |resource| persisted_file_set?(resource) && resource.id == record_set.id }

      Work.find(work.noid).darwin_core_xml = dwc

      expect(FileSet.find(record_set.id).tombstoned).to be_falsey
      expect(Work.find(work.noid).darwin_core?).to be(true)
    end
  end
end
