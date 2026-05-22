# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Permissions do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  describe 'STAFF_EDIT_GROUP' do
    it 'is the canonical Grouper string for DRS staff' do
      expect(Permissions::STAFF_EDIT_GROUP).to eq('northeastern:drs:repository:staff')
    end
  end

  describe '#delete_edit_group' do
    it 'removes a non-staff group when present' do
      work.add_edit_group('northeastern:editors')
      expect(work.edit_groups).to include('northeastern:editors')

      work.delete_edit_group('northeastern:editors')
      expect(work.edit_groups).not_to include('northeastern:editors')
    end

    it 'is a no-op when called with the staff group' do
      expect(work.edit_groups).to include(Permissions::STAFF_EDIT_GROUP)

      work.delete_edit_group(Permissions::STAFF_EDIT_GROUP)
      expect(work.edit_groups).to include(Permissions::STAFF_EDIT_GROUP)
    end

    it 'is a no-op when the named group is not present' do
      before_groups = work.edit_groups.to_a
      work.delete_edit_group('not:in:the:list')
      expect(work.edit_groups.to_a).to eq(before_groups)
    end
  end

  describe '#permissions' do
    it 'returns the resource class name as :type' do
      expect(community.permissions[:type]).to eq('Community')
      expect(collection.permissions[:type]).to eq('Collection')
      expect(work.permissions[:type]).to eq('Work')
    end
  end

  describe '#permissions=' do
    let(:base_hsh) do
      { embargo:        nil,
        depositor:      'nu1',
        proxy_uploader: 'nu1',
        edit_users:     ['nu1'],
        read:           ['public'],
        edit:           ['northeastern:editors'] }
    end

    it 'silently prepends the staff group when input :edit omits it' do
      work.permissions = base_hsh
      expect(work.edit_groups.to_a).to eq([Permissions::STAFF_EDIT_GROUP, 'northeastern:editors'])
    end

    it 'leaves :edit unchanged when input already contains the staff group' do
      work.permissions = base_hsh.merge(edit: ['northeastern:editors', Permissions::STAFF_EDIT_GROUP])
      expect(work.edit_groups.to_a).to eq(['northeastern:editors', Permissions::STAFF_EDIT_GROUP])
    end

    it 'treats nil :edit as empty and still seeds the staff group' do
      work.permissions = base_hsh.merge(edit: nil)
      expect(work.edit_groups.to_a).to eq([Permissions::STAFF_EDIT_GROUP])
    end

    it 'preserves :embargo, :depositor, :proxy_uploader, :edit_users, and :read assignment' do
      work.permissions = base_hsh.merge(embargo: '2026-12-31T00:00:00+00:00')

      expect(work.embargo_release_date.to_s).to start_with('2026-12-31')
      expect(work.depositor).to eq('nu1')
      expect(work.proxy_uploader).to eq('nu1')
      expect(work.edit_users.to_a).to eq(['nu1'])
      expect(work.read_groups.to_a).to eq(['public'])
    end
  end

  describe 'depositor and proxy_uploader as independent attributes' do
    # Pre-piece-3 the depositor= setter aliased edit_users, so writing
    # depositor wiped the ACL. The v2 fields are standalone — this spec
    # is the regression marker.
    it 'does NOT mutate edit_users when depositor is assigned' do
      work.permissions = { embargo: nil, depositor: nil, proxy_uploader: nil,
                           edit_users: ['nu_existing'], read: [], edit: [] }
      work.depositor = 'nu_new_owner'
      expect(work.edit_users.to_a).to eq(['nu_existing'])
    end

    it 'stores proxy_uploader independently of depositor' do
      work.depositor      = 'faculty_nuid'
      work.proxy_uploader = 'librarian_nuid'
      expect(work.depositor).to eq('faculty_nuid')
      expect(work.proxy_uploader).to eq('librarian_nuid')
    end
  end
end
