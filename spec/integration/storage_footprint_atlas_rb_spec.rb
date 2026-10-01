# frozen_string_literal: true

require 'rails_helper'

# Writes made through atlas_rb against the live server keep each owner's
# storage_bytes_ls current: the controller action batches its re-index, and the
# Solr doc matches the disk once the response is back.
RSpec.describe 'Storage footprint via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { ATLAS_RB_SERVER_ADMIN_NUID }
  let(:fixture)    { Rails.root.join('spec/fixtures/files/example.png').to_s }
  let(:revision)   { Rails.root.join('spec/fixtures/files/example.bin') }
  let(:collection) { CollectionCreator.call(parent_id: CommunityCreator.call.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid).tap { |w| AtlasRb::Work.complete(w.noid, nuid: admin_nuid) } }

  def indexed_bytes(resource)
    Atlas.index_adapter.connection
         .get('select', params: { q: %(id:"#{resource.id}"), fl: 'storage_bytes_ls' })
         .dig('response', 'docs', 0, 'storage_bytes_ls')
  end

  def bytes_on_disk(resource)
    StorageFootprintQuery.own_bytes(resource).tap do |recorded|
      walked = owned_keys(resource).sum { |key| Valkyrie.config.storage_adapter.measure_object(key: key).to_i }
      expect(recorded).to eq(walked)
    end
  end

  def owned_keys(resource, root: true)
    return [] if !root && StorageFootprintQuery::OWNER_TYPES.include?(resource.class.name)

    children = Atlas.query.find_inverse_references_by(resource: resource, property: :a_member_of).to_a +
               Atlas.query.find_members(resource: resource).to_a
    [resource.noid] + children.uniq(&:id).flat_map { |child| owned_keys(child, root: false) }
  end

  it 'counts a file deposited through the gem' do
    AtlasRb::Blob.create(work.noid, fixture, 'example.png', nuid: admin_nuid)

    expect(indexed_bytes(work)).to be > File.size(fixture)
    expect(indexed_bytes(work)).to eq(bytes_on_disk(Work.find(work.id)))
  end

  it 'counts a revision written through the gem' do
    blob = AtlasRb::Blob.create(work.noid, fixture, 'example.png', nuid: admin_nuid)
    before = indexed_bytes(work)

    AtlasRb::Blob.update(blob['id'], revision.to_s, nuid: admin_nuid)

    expect(indexed_bytes(work) - before).to be > revision.size
    expect(indexed_bytes(work)).to eq(bytes_on_disk(Work.find(work.id)))
  end

  it 'keeps counting a file withdrawn through the gem' do
    blob = AtlasRb::Blob.create(work.noid, fixture, 'example.png', nuid: admin_nuid)
    file_set = Atlas.query.find_parents(resource: Blob.find(blob['id'])).first

    AtlasRb::Resource.tombstone(file_set.noid, nuid: admin_nuid)

    expect(indexed_bytes(work)).to eq(bytes_on_disk(Work.find(work.id)))
    expect(owned_keys(Work.find(work.id))).to include(blob['id'])
  end

  it "counts a container's own MODS edits on the container" do
    before = indexed_bytes(collection)

    AtlasRb::Resource.put_mods(collection.noid, Rails.root.join('spec/fixtures/files/collection-mods.xml').to_s,
                               nuid: admin_nuid)

    expect(indexed_bytes(collection)).to be > before
    expect(indexed_bytes(collection)).to eq(bytes_on_disk(Collection.find(collection.id)))
  end
end
