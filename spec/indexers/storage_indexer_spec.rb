# frozen_string_literal: true

require 'rails_helper'

RSpec.describe StorageIndexer do
  let(:fixture)    { Rails.root.join('spec/fixtures/files/example.png').to_s }
  let(:revision)   { Rails.root.join('spec/fixtures/files/example.bin') }
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  # Completed, because an in-progress Work's figure waits for completion.
  let(:work) do
    created = WorkCreator.call(parent_id: collection.noid)
    created.in_progress = false
    Atlas.persister.save(resource: created)
  end
  let!(:blob) { BlobCreator.call(work_id: work.noid, path: fixture, original_filename: 'example.png') }

  after { Atlas.persister.wipe! }

  def solr
    Atlas.index_adapter.connection
  end

  def indexed_bytes(resource)
    solr.get('select', params: { q: %(id:"#{resource.id}"), fl: 'storage_bytes_ls' })
        .dig('response', 'docs').first&.fetch('storage_bytes_ls', nil)
  end

  # The objects a resource owns, walked through Valkyrie rather than SQL and
  # stopping at the next Work or container, measured on disk.
  def owned(resource, root: true)
    return [] if !root && StorageFootprintQuery::OWNER_TYPES.include?(resource.class.name)

    children = Atlas.query.find_inverse_references_by(resource: resource, property: :a_member_of).to_a +
               Atlas.query.find_members(resource: resource).to_a
    [resource] + children.uniq(&:id).flat_map { |child| owned(child, root: false) }
  end

  def bytes_on_disk(resources)
    resources.sum { |resource| Valkyrie.config.storage_adapter.measure_object(key: resource.noid).to_i }
  end

  it 'indexes the bytes a Work owns: itself, its FileSets and their Blobs' do
    expect(indexed_bytes(work)).to be > File.size(fixture)
    expect(indexed_bytes(work)).to eq(bytes_on_disk(owned(work)))
  end

  it "indexes a container's own objects and not its Works'" do
    expect(indexed_bytes(collection)).to eq(bytes_on_disk(owned(collection)))
    expect(owned(collection).map(&:id)).not_to include(work.id)
  end

  it 'lets a Solr sum over a subtree equal the bytes on disk' do
    subtree = [community, collection, work]
    facet = solr.get('select', params: {
                       q:            '*:*', rows: 0,
                       fq:           "id:(#{subtree.map { |r| %("#{r.id}") }.join(' OR ')})",
                       'json.facet': { total: 'sum(storage_bytes_ls)' }.to_json
                     })
    expect(facet.dig('facets', 'total').to_i).to eq(bytes_on_disk(subtree.flat_map { |r| owned(r) }))
  end

  it 'counts every revision once it is written' do
    before = indexed_bytes(work)
    BlobRevisionAppender.call(blob: Blob.find(blob.id), name: 'example.bin', source_path: revision.to_s)

    expect(indexed_bytes(work) - before).to be > revision.size
    expect(indexed_bytes(work)).to eq(bytes_on_disk(owned(work)))
  end

  it 'drops a purged FileSet from its Work' do
    file_set = Atlas.query.find_parents(resource: blob).first
    before = indexed_bytes(work)
    ResourcePurger.call(resource: file_set)

    expect(indexed_bytes(work)).to be < before
    expect(indexed_bytes(work)).to eq(bytes_on_disk(owned(Work.find(work.id))))
  end

  describe 'an in-progress Work', type: :request do
    it 'holds its figure until POST /works/:id/complete, then counts everything' do
      ingesting = WorkCreator.call(parent_id: collection.noid)
      BlobCreator.call(work_id: ingesting.noid, path: fixture, original_filename: 'page.png')
      expect(indexed_bytes(ingesting)).to be < bytes_on_disk(owned(ingesting))

      post "/works/#{ingesting.noid}/complete"
      expect(response).to have_http_status(:success)
      expect(indexed_bytes(ingesting)).to eq(bytes_on_disk(owned(Work.find(ingesting.id))))
    end
  end

  it 'leaves other types unindexed' do
    expect(described_class.new(resource: blob).to_solr).to eq({})
  end
end
