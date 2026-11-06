# frozen_string_literal: true

require 'rails_helper'

# A narrowing cascade cannot reach a tombstoned resource, so a restore narrows
# it to its parent's audience. See docs/resource-graph.md.
RSpec.describe 'Restore clamps to the parent', type: :request do
  let(:northeastern) { 'northeastern:drs:all' }
  let(:community)    { public_community! }
  let(:collection) do
    collection = CollectionCreator.call(parent_id: community.noid)
    collection.publicize
    Atlas.persister.save(resource: collection)
  end

  after { Atlas.persister.wipe! }

  def tombstoned(resource)
    resource.tombstone(by: '000000004')
    Atlas.persister.save(resource: resource)
  end

  def public_work
    work = WorkCreator.call(parent_id: collection.noid)
    work.publicize
    Atlas.persister.save(resource: work)
  end

  # Stands in for the cascade that skipped the tombstoned child.
  def narrow!(container, groups)
    container = Resource.find(container.noid)
    container.read_groups = groups
    Atlas.persister.save(resource: container)
  end

  def restore!(resource)
    post "/resources/#{resource.noid}/restore"
    expect(response).to have_http_status(:ok)
    Resource.find(resource.noid)
  end

  def restore_payload(resource)
    AuditEvent.for_resource(resource.id.to_s).where(action: 'restore').last.payload
  end

  it 'narrows a Work restored under a Collection narrowed since its tombstone' do
    work = tombstoned(public_work)
    narrow!(collection, [northeastern])

    restored = restore!(work)
    expect(restored.read_groups).to eq([northeastern])
    expect(restored.tombstoned).to be(false)
    expect(restore_payload(work)).to eq('read_before' => ['public'], 'read_after' => [northeastern])
  end

  it 'keeps the read groups of a Work restored under an unchanged parent' do
    work = tombstoned(public_work)

    expect(restore!(work).read_groups).to eq(['public'])
    expect(restore_payload(work)).not_to have_key('read_before')
  end

  it 'leaves only the editors and operators when the audiences share no group' do
    work = public_work
    work.read_groups = ['group-x']
    work = tombstoned(Atlas.persister.save(resource: work))
    narrow!(collection, ['group-y'])

    expect(restore!(work).read_groups).to eq([])
    expect(restore_payload(work)).to eq('read_before' => ['group-x'], 'read_after' => [])
  end

  it 'resolves a derivative tier no wider than the clamped read groups' do
    work = public_work
    work.derivative_permissions = JSON.dump(large: ['public'])
    work = tombstoned(Atlas.persister.save(resource: work))
    narrow!(collection, [northeastern])

    large = Delegate.new(use: Role.large_image.name)
    expect(restore!(work).derivative_gate_for(large)).to eq([northeastern])
  end

  it 'narrows a Collection restored under a narrowed Community' do
    child = tombstoned(collection)
    narrow!(community, [northeastern])

    expect(restore!(child).read_groups).to eq([northeastern])
  end

  it 'changes no ACL on a restored FileSet, which reads through its Work' do
    work = public_work
    file_set = tombstoned(FileSetCreator.call(work_id: work.noid, classification: Classification.generic))
    before = Array(FileSet.find(file_set.noid).read_groups)
    narrow!(work, [northeastern])

    expect(Array(restore!(file_set).read_groups)).to match_array(before)
  end

  it 'writes the clamped read groups to the preservation envelope' do
    work = tombstoned(public_work)
    narrow!(collection, [northeastern])
    restore!(work)

    expect(on_disk_permissions(work)['read']).to eq([northeastern])
  end
end
