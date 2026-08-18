# frozen_string_literal: true

require 'rails_helper'

# Section 6 of the OCFL Phase 2 plan — the bus-factor proof.
#
# Walk every on-disk OCFL storage root. Read every relationships.json /
# properties.json + permissions.json. Build a reconstituted graph from the
# JSON alone — no Postgres, no Solr — and assert it matches the live
# Atlas state.
#
# This is the test that justifies the whole Phase 2 envelope. If it
# passes, a librarian with disk access alone could rebuild the resource
# graph and ACLs from scratch.
RSpec.describe 'OCFL preservation reconstitution', type: :integration do
  # Wipe disk + Postgres before each example: this spec's assertions count
  # specific resource types on disk, so contamination from earlier specs in
  # the run would skew counts. The before(:suite) hook in rails_helper.rb
  # clears tmp/files once at suite start; per-example wiping here keeps each
  # bus-factor scenario hermetic.
  before do
    storage_roots.each { |root| FileUtils.rm_rf(root) }
    Atlas.persister.wipe!
  end

  # Every configured storage root, as an operator handed the mounts would have
  # them. Reading the paths off the adapter is how this harness learns where to
  # look; the walk below then uses nothing but the files.
  def storage_roots
    Valkyrie.config.storage_adapter.storage_roots.values.map(&:base_path)
  end

  # Walk every OCFL object in every root. For each, read its head-version
  # sidecars and return a hash keyed by NOID. This is what a reconstitution tool
  # without Atlas would do.
  def reconstitute_from_disk
    Dir.glob(storage_roots.map { |root| root.join('*', '*', '*').to_s })
       .each_with_object({}) do |object_root, by_noid|
      sidecar = read_sidecar(object_root)
      by_noid[File.basename(object_root)] = sidecar if sidecar.any?
    end
  end

  def read_sidecar(object_root)
    inventory_path = Pathname.new(object_root).join('inventory.json')
    return {} unless inventory_path.exist?

    inventory  = JSON.parse(inventory_path.read)
    head_state = inventory.fetch('versions').fetch(inventory.fetch('head')).fetch('state')
    head_state.each_with_object({}) do |(digest, paths), out|
      physical = Pathname.new(object_root).join(inventory.fetch('manifest').fetch(digest).first)
      paths.each do |logical_path|
        next unless logical_path.end_with?('.json')

        out[logical_path] = JSON.parse(physical.read, symbolize_names: true)
      end
    end
  end

  it 'tells an operator holding one storage root that the others exist' do
    WorkCreator.call(parent_id: CollectionCreator.call(parent_id: CommunityCreator.call.noid).noid)

    descriptors = storage_roots.map do |root|
      JSON.parse(root.join('extensions', 'neu-drs-storage-pool', 'config.json').read)
    end
    names = Valkyrie.config.storage_adapter.storage_roots.keys

    expect(descriptors.length).to eq(names.length)
    descriptors.each do |descriptor|
      expect(descriptor['pool']).to be_present
      expect(names).to include(descriptor['root'])
      # Each root names the rest, so a single mount reveals the pool's shape
      # without Atlas, its database, or its config file.
      expect(descriptor['siblings']).to eq(names - [descriptor['root']])
    end
  end

  it 'recovers the complete graph (Community → Collection → Work → FileSet → Blob) from disk' do
    fixture_path = Rails.root.join('spec/fixtures/files/example.png').to_s
    community  = CommunityCreator.call
    collection = CollectionCreator.call(parent_id: community.noid)
    work       = WorkCreator.call(parent_id: collection.noid)
    blob       = BlobCreator.call(path: fixture_path, work_id: work.noid, original_filename: 'example.png')

    recovered = reconstitute_from_disk

    expect(recovered).to include(community.noid, collection.noid, work.noid, blob.noid)

    expect(recovered[community.noid]['relationships.json'][:type]).to eq('Community')
    expect(recovered[community.noid]['relationships.json'][:a_member_of]).to eq([])

    expect(recovered[collection.noid]['relationships.json'][:type]).to eq('Collection')
    expect(recovered[collection.noid]['relationships.json'][:a_member_of]).to eq([community.noid])

    expect(recovered[work.noid]['relationships.json'][:type]).to eq('Work')
    expect(recovered[work.noid]['relationships.json'][:a_member_of]).to eq([collection.noid])

    expect(recovered[blob.noid]['properties.json'][:type]).to eq('Blob')
    expect(recovered[blob.noid]['properties.json'][:use]).to eq(Role.original_file.name)
    expect(recovered[blob.noid]['properties.json'][:original_filename]).to eq('example.png')
  end

  it 'recovers role-specific markers needed to distinguish MODS from content blobs' do
    community  = CommunityCreator.call
    collection = CollectionCreator.call(parent_id: community.noid)
    WorkCreator.call(parent_id: collection.noid) # creates a descriptive MODS Blob as a side effect

    recovered = reconstitute_from_disk

    blob_entries = recovered.values.select { |s| s.key?('properties.json') }
    mods_blobs   = blob_entries.select { |s| s['properties.json'][:use] == Role.descriptive_metadata.name }

    expect(mods_blobs.size).to be >= 1, 'expected at least one MODS Blob recoverable via use marker'
  end

  it 'distinguishes descriptive-metadata FileSets from generic FileSets via classification' do
    community  = CommunityCreator.call
    collection = CollectionCreator.call(parent_id: community.noid)
    work       = WorkCreator.call(parent_id: collection.noid)
    generic_fs = FileSetCreator.call(work_id: work.noid, classification: Classification.generic)

    recovered    = reconstitute_from_disk
    fs_entries   = recovered.values.select { |s| s.dig('relationships.json', :type) == 'FileSet' }
    descriptive  = fs_entries.select do |s|
      s['relationships.json'][:classification] == Classification.descriptive_metadata.name
    end
    generic = fs_entries.select do |s|
      s['relationships.json'][:classification] == Classification.generic.name
    end

    # Each Modsable resource (Community, Collection, Work) auto-creates its
    # own descriptive-metadata FileSet — three in this fixture. Plus we
    # explicitly created one generic.
    expect(descriptive.size).to eq(3)
    expect(generic.size).to eq(1)
    expect(generic.first['relationships.json'][:noid]).to eq(generic_fs.noid)
  end

  it 'recovers the parent-child graph by inverting a_member_of and member_ids edges' do
    community  = CommunityCreator.call
    collection = CollectionCreator.call(parent_id: community.noid)
    work       = WorkCreator.call(parent_id: collection.noid)

    recovered = reconstitute_from_disk
    edges = []
    recovered.each do |noid, sidecar|
      rel = sidecar['relationships.json']
      next unless rel

      Array(rel[:a_member_of]).each { |parent| edges << [parent, noid] }
      Array(rel[:member_ids]).each { |child| edges << [noid, child] }
    end
    edges.uniq!

    expect(edges).to include([community.noid, collection.noid])
    expect(edges).to include([collection.noid, work.noid])

    desc_fs = work.children.find { |c| c.is_a?(FileSet) && c.type == Classification.descriptive_metadata.name }
    expect(edges).to include([work.noid, desc_fs.noid]).or include([desc_fs.noid, work.noid])
  end

  it 'permissions from disk round-trip back into Permissions#permissions=' do
    community = CommunityCreator.call
    community.permissions = {
      embargo:        nil,
      depositor:      'nu999',
      proxy_uploader: 'nu999',
      edit_users:     ['nu999'],
      read:           ['public'],
      edit:           [Permissions::STAFF_EDIT_GROUP, 'northeastern:editors']
    }
    Atlas.persister.save(resource: community)
    community.write_preservation_envelope!

    recovered = reconstitute_from_disk
    perms_raw = recovered[community.noid]['permissions.json']
    perms = perms_raw.slice(:embargo, :depositor, :proxy_uploader, :edit_users, :read, :edit)

    fresh = Atlas.persister.save(resource: Community.new)
    fresh.permissions = perms
    fresh = Atlas.persister.save(resource: fresh)

    expect(fresh.depositor).to eq('nu999')
    expect(fresh.proxy_uploader).to eq('nu999')
    expect(fresh.edit_users.to_a).to eq(['nu999'])
    expect(fresh.read_groups).to eq(['public'])
    expect(fresh.edit_groups).to eq([Permissions::STAFF_EDIT_GROUP, 'northeastern:editors'])
  end
end
