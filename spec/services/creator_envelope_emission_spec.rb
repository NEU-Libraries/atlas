# frozen_string_literal: true

require 'rails_helper'

# Section 2 of the OCFL Phase 2 plan: every *Creator service emits the
# resource's preservation envelope (relationships.json or properties.json
# + permissions.json) on disk after the resource is saved. BlobCreator
# additionally re-emits the parent FileSet's envelope to reflect the
# mutated member_ids.
RSpec.describe 'Creator envelope emission' do
  def envelope_files_for(noid)
    object_root = Rails.root.join('tmp', 'files', noid[0..1], noid[2..3], noid)
    return [] unless object_root.exist?

    Dir.glob(object_root.join('v*', 'content', '*.json').to_s).map { |p| File.basename(p) }.uniq.sort
  end

  describe 'CommunityCreator.call' do
    it 'emits relationships.json + permissions.json for the new Community' do
      community = CommunityCreator.call

      expect(envelope_files_for(community.noid)).to include('relationships.json', 'permissions.json')
    end
  end

  describe 'CollectionCreator.call' do
    it 'emits relationships.json + permissions.json for the new Collection' do
      community = CommunityCreator.call
      collection = CollectionCreator.call(parent_id: community.noid)

      expect(envelope_files_for(collection.noid)).to include('relationships.json', 'permissions.json')
    end
  end

  describe 'WorkCreator.call' do
    it 'emits relationships.json + permissions.json for the new Work' do
      community = CommunityCreator.call
      collection = CollectionCreator.call(parent_id: community.noid)
      work = WorkCreator.call(parent_id: collection.noid)

      expect(envelope_files_for(work.noid)).to include('relationships.json', 'permissions.json')
    end
  end

  describe 'FileSetCreator.call' do
    it 'emits relationships.json + permissions.json for the new FileSet (descriptive_metadata)' do
      community = CommunityCreator.call
      collection = CollectionCreator.call(parent_id: community.noid)
      work = WorkCreator.call(parent_id: collection.noid)
      desc_fs = work.children.find { |c| c.is_a?(FileSet) && c.type == Classification.descriptive_metadata.name }

      expect(envelope_files_for(desc_fs.noid)).to include('relationships.json', 'permissions.json')
    end

    it 'emits relationships.json + permissions.json for a non-metadata FileSet (METS-bearing)' do
      community = CommunityCreator.call
      collection = CollectionCreator.call(parent_id: community.noid)
      work = WorkCreator.call(parent_id: collection.noid)

      fs = FileSetCreator.call(work_id: work.noid, classification: Classification.generic)

      expect(envelope_files_for(fs.noid)).to include('relationships.json', 'permissions.json')
    end
  end

  describe 'BlobCreator.call' do
    let(:fixture_path) { Rails.root.join('spec/fixtures/files/example.png').to_s }
    let(:work) do
      community = CommunityCreator.call
      collection = CollectionCreator.call(parent_id: community.noid)
      WorkCreator.call(parent_id: collection.noid)
    end

    it 'emits properties.json + permissions.json for the user-uploaded Blob' do
      blob = BlobCreator.call(path: fixture_path, work_id: work.noid, original_filename: 'example.png')

      expect(envelope_files_for(blob.noid)).to include('properties.json', 'permissions.json')
    end

    it 're-emits the parent FileSet envelope after attaching the Blob' do
      blob = BlobCreator.call(path: fixture_path, work_id: work.noid, original_filename: 'example.png')
      parent_fs = blob.parent

      # The parent FileSet now has at least the user Blob in member_ids; assert
      # the on-disk envelope reflects this by re-reading the latest state.
      object_root = Rails.root.join('tmp', 'files', parent_fs.noid[0..1], parent_fs.noid[2..3], parent_fs.noid)
      inventory = JSON.parse(File.read(object_root.join('inventory.json')))
      head_state = inventory.fetch('versions').fetch(inventory.fetch('head')).fetch('state')
      digest, = head_state.find { |_d, paths| paths.include?('relationships.json') }
      physical = inventory.fetch('manifest').fetch(digest).first
      relationships = JSON.parse(File.read(object_root.join(physical)), symbolize_names: true)

      expect(relationships[:member_ids]).to include(blob.noid)
    end
  end
end
