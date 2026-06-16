# frozen_string_literal: true

require 'rails_helper'

# Drives the atlas_rb 1.3.4 Compilation (Sets) surface through the real HTTP
# boundary: owner-scoped CRUD, the six recipe-membership calls, recipe
# resolution via /contents, and the typed rejection paths
# (AtlasRb::CompilationError on a 422, AtlasRb::ForbiddenError on a 403).
#
# The gem always presents the cerberus bearer token, so there is no
# unauthenticated-guest path here — the guest/public matrix is covered by
# the request specs (spec/requests/compilations_spec.rb). Works born from
# the creators are private (empty read_groups), so contents resolution is
# asserted as admin, who skips the gated-discovery ACL filter.
RSpec.describe 'Compilations via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { '000000004' }

  # Owner (standard role) and a signed-in non-owner for the 403 paths,
  # created on the shared DB so the Puma server thread resolves them.
  let!(:curator) do
    User.find_by(nuid: '000000002') ||
      User.create!(email: 'curator-sets@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000002', name: 'Doe, Jane', role: :standard)
  end
  let!(:rando) do
    User.find_by(nuid: '000000003') ||
      User.create!(email: 'rando-sets@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000003', name: 'Roe, Riley', role: :standard)
  end

  # community ── collection (included) ── nested ── nested_work
  #           │                        └─ work, excluded_work
  #           └─ other ── stray_work (included individually)
  #
  # let! (not let): the whole tree must exist before /contents resolves the
  # recipe — a lazily-built Work referenced only in the assertion would be
  # created after the Solr query already ran.
  let!(:community)     { CommunityCreator.call }
  let!(:collection)    { CollectionCreator.call(parent_id: community.noid) }
  let!(:nested)        { CollectionCreator.call(parent_id: collection.noid) }
  let!(:other)         { CollectionCreator.call(parent_id: community.noid) }
  let!(:work)          { WorkCreator.call(parent_id: collection.noid) }
  let!(:nested_work)   { WorkCreator.call(parent_id: nested.noid) }
  let!(:excluded_work) { WorkCreator.call(parent_id: collection.noid) }
  let!(:stray_work)    { WorkCreator.call(parent_id: other.noid) }

  def create_set(title: 'Course readings', nuid: curator.nuid)
    AtlasRb::Compilation.create(title, description: 'HIST 1101', nuid: nuid)
  end

  it 'round-trips create / find / update / list / destroy through the HTTP boundary' do
    set = create_set
    expect(set['id']).to be_present
    expect(set['depositor']).to eq(curator.nuid)
    expect(set['read_groups']).to eq([]) # born private, no staff default

    expect(AtlasRb::Compilation.find(set['id'], nuid: curator.nuid)['title'])
      .to eq('Course readings')

    renamed = AtlasRb::Compilation.update(set['id'], title: 'Renamed', nuid: curator.nuid)
    expect(renamed['title']).to eq('Renamed')
    expect(renamed['description']).to eq('HIST 1101')

    listing = AtlasRb::Compilation.list(nuid: curator.nuid)
    expect(listing['compilations'].map { |entry| entry.dig('compilation', 'id') })
      .to include(set['id'])
    expect(listing['pagination']).to be_present

    filtered = AtlasRb::Compilation.list(q: 'renam', nuid: curator.nuid)
    expect(filtered['compilations'].map { |entry| entry.dig('compilation', 'id') })
      .to eq([set['id']])
    expect(filtered.dig('pagination', 'count')).to eq(1)
    expect(AtlasRb::Compilation.list(q: 'no-such-set', nuid: curator.nuid)['compilations'])
      .to eq([])

    response = AtlasRb::Compilation.destroy(set['id'], nuid: curator.nuid)
    expect(response.status).to eq(204)
    expect(Compilation.find_by(noid: set['id'])).to be_nil
  end

  it 'manages the recipe and resolves contents (union minus set-asides)' do
    set = create_set

    after_collection = AtlasRb::Compilation.add_included_collection(
      set['id'], collection.noid, nuid: curator.nuid
    )
    expect(after_collection['included_collections']).to eq([collection.noid])

    after_work = AtlasRb::Compilation.add_included_work(set['id'], stray_work.noid, nuid: curator.nuid)
    expect(after_work['included_works']).to eq([stray_work.noid])

    after_exclusion = AtlasRb::Compilation.add_exclusion(set['id'], excluded_work.noid, nuid: curator.nuid)
    expect(after_exclusion['excluded_works']).to eq([excluded_work.noid])

    resolved = AtlasRb::Compilation.contents(set['id'], nuid: admin_nuid)
    expect(resolved['contents'].pluck('noid'))
      .to contain_exactly(work.noid, nested_work.noid, stray_work.noid)
    expect(resolved.dig('pagination', 'total')).to eq(3)
    expect(resolved['contents'].first['klass']).to eq('Work')

    # Put the set-aside back: the work rejoins the resolved union.
    AtlasRb::Compilation.remove_exclusion(set['id'], excluded_work.noid, nuid: curator.nuid)
    expect(AtlasRb::Compilation.contents(set['id'], nuid: admin_nuid).dig('pagination', 'total')).to eq(4)

    # Remove the collection inclusion: only the individually-added work remains.
    after_removal = AtlasRb::Compilation.remove_included_collection(
      set['id'], collection.noid, nuid: curator.nuid
    )
    expect(after_removal['included_collections']).to eq([])
    expect(AtlasRb::Compilation.contents(set['id'], nuid: admin_nuid)['contents']
      .pluck('noid')).to eq([stray_work.noid])
  end

  it 'is idempotent on membership adds and removes' do
    set = create_set
    AtlasRb::Compilation.add_included_work(set['id'], work.noid, nuid: curator.nuid)
    after_second = AtlasRb::Compilation.add_included_work(set['id'], work.noid, nuid: curator.nuid)
    expect(after_second['included_works']).to eq([work.noid])

    AtlasRb::Compilation.remove_included_work(set['id'], work.noid, nuid: curator.nuid)
    after_absent = AtlasRb::Compilation.remove_included_work(set['id'], work.noid, nuid: curator.nuid)
    expect(after_absent['included_works']).to eq([])
  end

  it 'replaces the ACL via update(permissions:) and audits the change' do
    set = create_set

    updated = AtlasRb::Compilation.update(
      set['id'],
      permissions: { read: ['public'], edit: [], edit_users: [rando.nuid] },
      nuid:        curator.nuid
    )
    expect(updated['read_groups']).to eq(['public'])
    expect(updated['edit_users']).to eq([rando.nuid])
    expect(updated['depositor']).to eq(curator.nuid) # never writable

    events = AuditEvent.where(resource_type: 'Compilation', change_type: 'permissions')
    expect(events.count).to eq(1)
    expect(events.first.payload.dig('after', 'read')).to eq(['public'])

    # The grant is live: the grantee can now edit through the gem.
    expect(AtlasRb::Compilation.update(set['id'], title: 'By grantee', nuid: rando.nuid)['title'])
      .to eq('By grantee')
  end

  it 'raises AtlasRb::CompilationError when a membership noid is the wrong type' do
    set = create_set

    expect do
      AtlasRb::Compilation.add_included_collection(set['id'], community.noid, nuid: curator.nuid)
    end.to raise_error(AtlasRb::CompilationError) { |e|
      expect(e.code).to eq('invalid_record')
    }

    expect do
      AtlasRb::Compilation.add_included_work(set['id'], collection.noid, nuid: curator.nuid)
    end.to raise_error(AtlasRb::CompilationError)

    expect(AtlasRb::Compilation.find(set['id'], nuid: curator.nuid)['included_collections']).to eq([])
  end

  it 'raises AtlasRb::CompilationError on a blank-title create' do
    expect do
      AtlasRb::Compilation.create('', nuid: curator.nuid)
    end.to raise_error(AtlasRb::CompilationError) { |e|
      expect(e.code).to eq('invalid_record')
    }
  end

  it 'lists grant-scoped Sets (editable / shared), excluding owned' do
    group = 'northeastern:drs:test-readers'
    curator.update!(groups: [group])
    Compilation.delete_all # deterministic baseline (AR rows survive the Valkyrie wipe)

    # rando owns these and grants curator three different ways.
    editable_user  = create_set(title: 'Editable via edit_users', nuid: rando.nuid)
    editable_group = create_set(title: 'Editable via edit_group', nuid: rando.nuid)
    read_only      = create_set(title: 'Read-only to me',         nuid: rando.nuid)
    create_set(title: 'Not shared with me', nuid: rando.nuid)
    owned = create_set(title: 'Owned by me', nuid: curator.nuid)

    AtlasRb::Compilation.update(editable_user['id'],
                                permissions: { read: [], edit: [], edit_users: [curator.nuid] },
                                nuid:        rando.nuid)
    AtlasRb::Compilation.update(editable_group['id'],
                                permissions: { read: [], edit: [group], edit_users: [] },
                                nuid:        rando.nuid)
    AtlasRb::Compilation.update(read_only['id'],
                                permissions: { read: [group], edit: [], edit_users: [] },
                                nuid:        rando.nuid)

    editable_ids = AtlasRb::Compilation.list(scope: :editable, nuid: curator.nuid)['compilations']
                                       .map { |e| e.dig('compilation', 'id') }
    expect(editable_ids).to contain_exactly(editable_user['id'], editable_group['id'])

    shared_ids = AtlasRb::Compilation.list(scope: :shared, nuid: curator.nuid)['compilations']
                                     .map { |e| e.dig('compilation', 'id') }
    expect(shared_ids).to contain_exactly(editable_user['id'], editable_group['id'], read_only['id'])
    expect(shared_ids).not_to include(owned['id'])
  end

  it 'raises AtlasRb::ForbiddenError for non-owner writes and cross-owner listing' do
    set = create_set

    expect do
      AtlasRb::Compilation.update(set['id'], title: 'Hijack', nuid: rando.nuid)
    end.to raise_error(AtlasRb::ForbiddenError) { |e|
      expect(e.action).to eq('update')
      expect(e.subject).to eq('Compilation')
    }

    expect do
      AtlasRb::Compilation.list(owner: curator.nuid, nuid: rando.nuid)
    end.to raise_error(AtlasRb::ForbiddenError)

    # And a private Set is unreadable to a non-grantee (per-row :read rule).
    expect do
      AtlasRb::Compilation.find(set['id'], nuid: rando.nuid)
    end.to raise_error(AtlasRb::ForbiddenError)
  end
end
