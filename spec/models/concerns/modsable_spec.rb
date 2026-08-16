# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Modsable do
  let(:community) { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work) { WorkCreator.call(parent_id: collection.noid) }

  def envelope_files_for(noid)
    object_root = Rails.root.join('tmp', 'files', noid[0..1], noid[2..3], noid)
    return [] unless object_root.exist?

    Dir.glob(object_root.join('v*', 'content', '*.json').to_s).map { |p| File.basename(p) }.uniq.sort
  end

  def latest_relationships(noid)
    object_root = Rails.root.join('tmp', 'files', noid[0..1], noid[2..3], noid)
    inventory = JSON.parse(File.read(object_root.join('inventory.json')))
    head_state = inventory.fetch('versions').fetch(inventory.fetch('head')).fetch('state')
    digest, = head_state.find { |_d, paths| paths.include?('relationships.json') }
    physical = inventory.fetch('manifest').fetch(digest).first
    JSON.parse(File.read(object_root.join(physical)), symbolize_names: true)
  end

  describe '#mods_xml=' do
    it 'stores the descriptive-metadata blob under the canonical descMetadata.xml filename' do
      stored_id = work.mods_blob.file_identifiers.last.to_s
      expect(stored_id).to end_with('/descMetadata.xml')
    end

    it 'emits a properties.json envelope for the new MODS Blob' do
      expect(envelope_files_for(work.mods_blob.noid)).to include('properties.json', 'permissions.json')
    end

    it 're-emits the descriptive-metadata FileSet relationships.json with the MODS Blob in member_ids' do
      desc_fs = work.children.find { |c| c.is_a?(FileSet) && c.type == Classification.descriptive_metadata.name }
      relationships = latest_relationships(desc_fs.noid)
      expect(relationships[:member_ids]).to include(work.mods_blob.noid)
    end

    # A Work assembled without its creator has no FileSet to attach the Blob
    # to. The write has to fail before it persists one, or the failure leaves
    # an unreferenced Blob in Postgres and Solr that nothing will ever reach.
    it 'persists no orphan Blob when there is no descriptive-metadata FileSet' do
      bare   = Atlas.persister.save(resource: Work.new(a_member_of: collection.id))
      before = Atlas.query.find_all_of_model(model: Blob).count

      expect { bare.mods_xml = bare.mods_template }.to raise_error(/no descriptive-metadata FileSet/)
      expect(Atlas.query.find_all_of_model(model: Blob).count).to eq(before)
    end
  end

  describe '#mods_writable?' do
    it 'is true for a Work built through its creator' do
      expect(work.mods_writable?).to be(true)
    end

    it 'is false for a Work with no descriptive-metadata FileSet' do
      bare = Atlas.persister.save(resource: Work.new(a_member_of: collection.id))

      expect(bare.mods_writable?).to be(false)
    end
  end
end
