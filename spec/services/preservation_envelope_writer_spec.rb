# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PreservationEnvelopeWriter do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:descriptive_fs) do
    work.children.find { |c| c.is_a?(FileSet) && c.type == Classification.descriptive_metadata.name }
  end
  let(:mods_blob) { descriptive_fs.files.first }

  # Tuple (2,2) per OCFL extension 0007 — first 4 NOID chars become directory tuples.
  def object_root_for(noid)
    Rails.root.join('tmp', 'files', noid[0..1], noid[2..3], noid)
  end

  # Navigate the OCFL inventory to find a logical file's physical content
  # path. Each create_file call cuts a new version, so we look up the
  # filename in the head state, get its digest, and resolve to the
  # manifest's physical path (which lives in whichever vN/content/ first
  # introduced it).
  def latest_content(noid, filename)
    object_root = object_root_for(noid)
    inventory = JSON.parse(File.read(object_root.join('inventory.json')))
    head_state = inventory.fetch('versions').fetch(inventory.fetch('head')).fetch('state')
    digest, = head_state.find { |_d, paths| paths.include?(filename) }
    raise "no #{filename} in #{inventory['head']} of #{noid}" unless digest

    physical = inventory.fetch('manifest').fetch(digest).first
    JSON.parse(File.read(object_root.join(physical)), symbolize_names: true)
  end

  describe '.call' do
    it 'writes relationships.json and permissions.json to a Work\'s OCFL object' do
      described_class.call(resource: work)

      object_root = object_root_for(work.noid)
      expect(object_root).to exist
      expect(latest_content(work.noid, 'relationships.json')[:type]).to eq('Work')
      expect(latest_content(work.noid, 'permissions.json')).to have_key(:embargo)
    end

    it 'writes properties.json (not relationships.json) for a Blob' do
      described_class.call(resource: mods_blob)

      properties = latest_content(mods_blob.noid, 'properties.json')
      expect(properties[:type]).to eq('Blob')
      expect(properties[:use]).to eq(Role.descriptive_metadata.name)

      relationships_path = object_root_for(mods_blob.noid).join('v1', 'content', 'relationships.json')
      expect(File).not_to exist(relationships_path)
    end

    it 'writes both files for a Community (root, no parent permissions)' do
      described_class.call(resource: community)

      relationships = latest_content(community.noid, 'relationships.json')
      permissions = latest_content(community.noid, 'permissions.json')

      expect(relationships[:type]).to eq('Community')
      expect(relationships[:a_member_of]).to eq([])
      expect(permissions[:embargo]).to be_nil
    end

    it 'serializes member_ids and a_member_of as NOIDs' do
      described_class.call(resource: collection)
      relationships = latest_content(collection.noid, 'relationships.json')

      expect(relationships[:a_member_of]).to eq([community.noid])
      relationships[:a_member_of].each { |id| expect(id).not_to include('-') } # not a UUID
    end

    it 'permissions.json round-trips through Permissions#permissions=' do
      work.permissions = {
        embargo:        '2026-12-31T00:00:00+00:00',
        depositor:      'nu123',
        proxy_uploader: 'nu456',
        edit_users:     %w[nu123 nu456],
        read:           ['public'],
        edit:           [Permissions::STAFF_EDIT_GROUP, 'northeastern:editors']
      }
      Atlas.persister.save(resource: work)
      described_class.call(resource: work)

      raw = latest_content(work.noid, 'permissions.json')
      # Strip envelope-only keys before feeding to the setter.
      hsh = raw.slice(:embargo, :depositor, :proxy_uploader, :edit_users, :read, :edit)

      fresh_work = WorkCreator.call(parent_id: collection.noid)
      fresh_work.permissions = hsh
      Atlas.persister.save(resource: fresh_work)
      reloaded = Work.find(fresh_work.id)

      expect(reloaded.depositor).to eq('nu123')
      expect(reloaded.proxy_uploader).to eq('nu456')
      expect(reloaded.edit_users.to_a).to eq(%w[nu123 nu456])
      expect(reloaded.read_groups).to eq(['public'])
      expect(reloaded.edit_groups).to eq([Permissions::STAFF_EDIT_GROUP, 'northeastern:editors'])
      expect(reloaded.embargo_release_date.to_s).to start_with('2026-12-31')
    end

    it 're-raises StorageAdapter errors after logging' do
      expect(Rails.logger).to receive(:error).with(/envelope write failed.*#{work.noid}/)
      allow_any_instance_of(Valkyrie::Storage::OCFL).to receive(:upload).and_raise(StandardError, 'boom')

      expect { described_class.call(resource: work) }.to raise_error(StandardError, 'boom')
    end

    it 'cuts a new OCFL version on the resource\'s object when content changed' do
      described_class.call(resource: work)
      head_v1 = JSON.parse(File.read(object_root_for(work.noid).join('inventory.json')))['head']

      work.permissions = {
        embargo: nil, depositor: 'nu999', proxy_uploader: 'nu999',
        edit_users: ['nu999'], read: ['public'], edit: []
      }
      Atlas.persister.save(resource: work)
      described_class.call(resource: work)
      head_v2 = JSON.parse(File.read(object_root_for(work.noid).join('inventory.json')))['head']

      expect(head_v2).not_to eq(head_v1)
    end
  end

  describe '.call signature' do
    it 'follows ApplicationService kwargs convention' do
      expect { described_class.call(resource: work) }.not_to raise_error
    end
  end
end
