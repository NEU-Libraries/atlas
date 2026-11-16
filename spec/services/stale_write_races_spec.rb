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
end
