# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Preservable do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:descriptive_fs) do
    work.children.find { |c| c.is_a?(FileSet) && c.type == Classification.descriptive_metadata.name }
  end
  let(:mods_blob) { descriptive_fs.files.first }

  describe '#graph_payload' do
    context 'on a root Community' do
      it 'reports type, empty a_member_of, empty member_ids' do
        payload = community.graph_payload
        expect(payload[:schema_version]).to eq(1)
        expect(payload[:noid]).to eq(community.noid)
        expect(payload[:type]).to eq('Community')
        expect(payload[:classification]).to eq('Community')
        expect(payload[:a_member_of]).to eq([])
        expect(payload[:member_ids]).to eq([])
      end
    end

    context 'on a Collection with a parent Community' do
      it 'reports the parent NOID (not Valkyrie ID) in a_member_of' do
        payload = collection.graph_payload
        expect(payload[:type]).to eq('Collection')
        expect(payload[:a_member_of]).to eq([community.noid])
        expect(payload[:member_ids]).to eq([])
      end
    end

    context 'on a Work with a parent Collection' do
      it 'reports the parent NOID in a_member_of' do
        payload = work.graph_payload
        expect(payload[:type]).to eq('Work')
        expect(payload[:a_member_of]).to eq([collection.noid])
      end
    end

    context 'on a FileSet' do
      it 'reports its classification distinct from type, plus member NOIDs' do
        fs_reloaded = FileSet.find(descriptive_fs.id) # ensure fresh member_ids after MODS write
        payload = fs_reloaded.graph_payload

        expect(payload[:type]).to eq('FileSet')
        expect(payload[:classification]).to eq(Classification.descriptive_metadata.name)
        expect(payload[:a_member_of]).to eq([work.noid])
        expect(payload[:member_ids]).to include(mods_blob.noid)
        # NOIDs only — never Valkyrie ID UUIDs
        payload[:member_ids].each { |id| expect(id).not_to include('/') }
      end
    end

    context 'on a Blob (overrides graph_payload to emit properties shape)' do
      # Modsable creates the MODS Blob without populating Blob#original_filename
      # (the filename lives in the OCFL inventory's logical_path); that's
      # preservation-fine. We assert the load-bearing fields here and use a
      # user-uploaded Blob below to cover the populated-filename case.
      it 'reports the role-bearing fields needed for preservation' do
        payload = mods_blob.graph_payload

        expect(payload[:schema_version]).to eq(1)
        expect(payload[:noid]).to eq(mods_blob.noid)
        expect(payload[:type]).to eq('Blob')
        expect(payload[:use]).to eq(Role.descriptive_metadata.name)
        expect(payload).to have_key(:original_filename)
        expect(payload).to have_key(:mime_type)
        expect(payload).to have_key(:size)
        expect(payload).to have_key(:label)
      end

      it 'reports populated original_filename / mime_type / size for a user-uploaded Blob' do
        path = Rails.root.join('spec/fixtures/files/example.png').to_s
        blob = BlobCreator.call(path: path, work_id: work.noid, original_filename: 'example.png')

        payload = blob.graph_payload
        expect(payload[:original_filename]).to eq('example.png')
        expect(payload[:mime_type]).to start_with('image/')
        expect(payload[:size]).to be_present
      end

      it 'does not leak relationships fields into properties shape' do
        payload = mods_blob.graph_payload

        expect(payload).not_to have_key(:a_member_of)
        expect(payload).not_to have_key(:member_ids)
        expect(payload).not_to have_key(:classification)
      end
    end
  end

  describe '#graph_filename' do
    it 'returns relationships.json for graph nodes' do
      expect(community.graph_filename).to eq('relationships.json')
      expect(collection.graph_filename).to eq('relationships.json')
      expect(work.graph_filename).to eq('relationships.json')
      expect(descriptive_fs.graph_filename).to eq('relationships.json')
    end

    it 'returns properties.json for Blobs' do
      expect(mods_blob.graph_filename).to eq('properties.json')
    end
  end

  describe '#permissions_payload' do
    it 'mirrors the keys Permissions#permissions= consumes' do
      payload = work.permissions_payload

      expect(payload[:schema_version]).to eq(1)
      expect(payload[:noid]).to eq(work.noid)
      expect(payload).to have_key(:embargo)
      expect(payload).to have_key(:depositor)
      expect(payload).to have_key(:read)
      expect(payload).to have_key(:edit)
    end

    it 'reflects mutations to permissions (round-trip via setter)' do
      work.permissions = {
        embargo: '2026-12-31T00:00:00+00:00',
        depositor: ['nu123'],
        read: ['public'],
        edit: ['northeastern:editors']
      }
      Atlas.persister.save(resource: work)

      reloaded = Work.find(work.id)
      payload = reloaded.permissions_payload

      expect(payload[:depositor]).to eq(['nu123'])
      expect(payload[:read]).to eq(['public'])
      expect(payload[:edit]).to eq(['northeastern:editors'])
      expect(payload[:embargo]).to start_with('2026-12-31')
    end

    it 'serializes nil embargo as nil (not the empty string)' do
      payload = community.permissions_payload
      expect(payload[:embargo]).to be_nil
    end
  end
end
