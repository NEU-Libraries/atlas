# frozen_string_literal: true

require 'rails_helper'

# Section 4 of the OCFL Phase 2 plan: controllers wire the writer into
# state-changing update paths. metadata_update fires (permissions may have
# changed), binary_update does NOT (only MODS XML moved, the resource's
# envelope is untouched), and blob#destroy re-emits the parent FileSet's
# relationships.json now that member_ids shrunk.
RSpec.describe 'Controller envelope emission' do
  after { Atlas.persister.wipe! }

  def head_version_for(noid)
    object_root = Rails.root.join('tmp', 'files', noid[0..1], noid[2..3], noid)
    return nil unless object_root.exist?

    inventory = JSON.parse(File.read(object_root.join('inventory.json')))
    inventory.fetch('head')
  end

  def latest_relationships(noid)
    object_root = Rails.root.join('tmp', 'files', noid[0..1], noid[2..3], noid)
    inventory = JSON.parse(File.read(object_root.join('inventory.json')))
    head_state = inventory.fetch('versions').fetch(inventory.fetch('head')).fetch('state')
    digest, = head_state.find { |_d, paths| paths.include?('relationships.json') }
    physical = inventory.fetch('manifest').fetch(digest).first
    JSON.parse(File.read(object_root.join(physical)), symbolize_names: true)
  end

  describe WorksController, type: :controller do
    render_views

    let(:community)  { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }
    let(:work)       { WorkCreator.call(parent_id: collection.noid) }

    it 'metadata_update bumps the Work envelope head' do
      head_before = head_version_for(work.noid)

      patch :update,
            params: { id: work.noid, metadata: { permissions: { read: ['public'], edit: [], edit_users: [] } } },
            as:     :json

      expect(head_version_for(work.noid)).not_to eq(head_before)
    end

    it 'binary_update does NOT bump the Work envelope head (MODS-only change)' do
      head_before = head_version_for(work.noid)

      patch :update,
            params: { id:     work.noid,
                      binary: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) },
            as:     :json

      expect(head_version_for(work.noid)).to eq(head_before)
    end
  end

  describe CollectionsController, type: :controller do
    render_views

    let(:community)  { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }

    it 'metadata_update bumps the Collection envelope head' do
      head_before = head_version_for(collection.noid)

      patch :update,
            params: { id: collection.noid, metadata: { permissions: { read: ['public'], edit: [], edit_users: [] } } },
            as:     :json

      expect(head_version_for(collection.noid)).not_to eq(head_before)
    end
  end

  describe CommunitiesController, type: :controller do
    render_views

    let(:community) { CommunityCreator.call }

    it 'metadata_update bumps the Community envelope head' do
      head_before = head_version_for(community.noid)

      patch :update,
            params: { id: community.noid, metadata: { permissions: { read: ['public'], edit: [], edit_users: [] } } },
            as:     :json

      expect(head_version_for(community.noid)).not_to eq(head_before)
    end
  end

  describe BlobsController, type: :controller do
    render_views

    let(:community)  { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }
    let(:work)       { WorkCreator.call(parent_id: collection.noid) }
    let(:fixture_path) { Rails.root.join('spec/fixtures/files/example.png').to_s }

    it 'destroy re-emits the parent FileSet relationships.json with the Blob removed from member_ids' do
      blob = BlobCreator.call(path: fixture_path, work_id: work.noid, original_filename: 'example.png')
      parent_fs = blob.parent

      delete :destroy, params: { id: blob.noid }, as: :json
      expect(response).to have_http_status(:success)

      relationships = latest_relationships(parent_fs.noid)
      expect(relationships[:member_ids]).not_to include(blob.noid)
    end
  end
end
