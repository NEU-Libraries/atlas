# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Compilation do
  let!(:community)  { Atlas.persister.save(resource: Community.new) }
  let!(:collection) { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
  let!(:work)       { Atlas.persister.save(resource: Work.new(a_member_of: collection.id)) }

  let(:compilation) { described_class.create!(title: 'My Set', depositor: '001234567') }

  describe 'validations' do
    it 'requires a title' do
      expect(described_class.new(depositor: '001234567')).not_to be_valid
    end

    it 'requires a depositor' do
      expect(described_class.new(title: 'My Set')).not_to be_valid
    end
  end

  describe 'noid minting' do
    it 'mints a noid on create' do
      expect(compilation.noid).to be_present
    end

    it 'keeps a pre-assigned noid' do
      preset = described_class.create!(title: 'T', depositor: 'n', noid: 'custom1')
      expect(preset.noid).to eq('custom1')
    end

    it 'enforces noid uniqueness at the constraint level' do
      compilation
      expect do
        described_class.create!(title: 'T', depositor: 'n', noid: compilation.noid)
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe 'membership join models' do
    it 'accepts a Collection noid as a collection inclusion' do
      row = compilation.collection_inclusions.create!(resource_noid: collection.noid)
      expect(row).to be_persisted
      expect(compilation.included_collections).to eq([collection.noid])
    end

    it 'accepts a Work noid as a work inclusion and as an exclusion' do
      compilation.work_inclusions.create!(resource_noid: work.noid)
      compilation.exclusions.create!(resource_noid: work.noid)

      expect(compilation.included_works).to eq([work.noid])
      expect(compilation.excluded_works).to eq([work.noid])
    end

    it 'rejects a Community noid (no top-node includes)' do
      row = compilation.collection_inclusions.build(resource_noid: community.noid)
      expect(row).not_to be_valid
      expect(row.errors[:resource_noid]).to include('must resolve to a Collection')
    end

    it 'rejects a Work noid as a collection inclusion' do
      expect(compilation.collection_inclusions.build(resource_noid: work.noid)).not_to be_valid
    end

    it 'rejects a Collection noid as a work inclusion' do
      expect(compilation.work_inclusions.build(resource_noid: collection.noid)).not_to be_valid
    end

    it 'rejects an unknown noid' do
      expect(compilation.work_inclusions.build(resource_noid: 'nope404')).not_to be_valid
    end

    it 'enforces per-compilation uniqueness at the constraint level' do
      compilation.work_inclusions.create!(resource_noid: work.noid)
      expect do
        compilation.work_inclusions.create!(resource_noid: work.noid)
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'deletes join rows with the compilation' do
      compilation.work_inclusions.create!(resource_noid: work.noid)
      compilation.destroy!
      expect(Compilation::WorkInclusion.where(resource_noid: work.noid)).to be_empty
    end
  end

  describe '.granted_to (grant-scoped listing)' do
    let(:group) { 'northeastern:drs:test-readers' }
    let!(:by_edit_user)  { described_class.create!(title: 'edit_user',  depositor: 'owner', edit_users: ['000000002']) }
    let!(:by_edit_group) { described_class.create!(title: 'edit_group', depositor: 'owner', edit_groups: [group]) }
    let!(:by_read_group) { described_class.create!(title: 'read_group', depositor: 'owner', read_groups: [group]) }
    let!(:owned)         { described_class.create!(title: 'owned',      depositor: '000000002', edit_groups: [group]) }
    let!(:unrelated)     { described_class.create!(title: 'unrelated',  depositor: 'owner') }

    it 'editable (include_read: false) returns edit grants, never owned or read-only' do
      titles = described_class.granted_to(nuid: '000000002', groups: [group], include_read: false).map(&:title)
      expect(titles).to contain_exactly('edit_user', 'edit_group')
    end

    it 'shared (include_read: true) adds read grants, still excluding owned' do
      titles = described_class.granted_to(nuid: '000000002', groups: [group], include_read: true).map(&:title)
      expect(titles).to contain_exactly('edit_user', 'edit_group', 'read_group')
    end

    it 'matches edit_users even with no groups' do
      titles = described_class.granted_to(nuid: '000000002', groups: [], include_read: true).map(&:title)
      expect(titles).to eq(['edit_user'])
    end

    it 'returns nothing for a principal with no nuid and no groups' do
      expect(described_class.granted_to(nuid: nil, groups: [], include_read: true)).to be_empty
    end

    it 'orders newest-first' do
      scope = described_class.granted_to(nuid: '000000002', groups: [group], include_read: true)
      expect(scope.to_a).to eq(scope.order(created_at: :desc).to_a)
    end
  end

  describe 'ACL helpers (Compilation::ACL)' do
    it 'round-trips read groups' do
      compilation.add_read_group('northeastern:all')
      expect(compilation.read_groups).to eq(['northeastern:all'])
      compilation.delete_read_group('northeastern:all')
      expect(compilation.read_groups).to eq([])
    end

    it 'publicize / privatize toggle public?' do
      expect(compilation).not_to be_public
      compilation.publicize
      expect(compilation).to be_public
      compilation.privatize
      expect(compilation).not_to be_public
    end

    it 'does NOT auto-prepend the staff edit group (F2 divergence)' do
      compilation.permissions = { edit: ['some:group'], read: [], edit_users: [] }
      expect(compilation.edit_groups).to eq(['some:group'])
      expect(compilation.edit_groups).not_to include(Permissions::STAFF_EDIT_GROUP)
    end

    it 'allows deleting the staff edit group (no resource-side guard)' do
      compilation.add_edit_group(Permissions::STAFF_EDIT_GROUP)
      compilation.delete_edit_group(Permissions::STAFF_EDIT_GROUP)
      expect(compilation.edit_groups).to be_empty
    end

    it 'permissions= never touches depositor' do
      compilation.permissions = { read: ['public'], edit: [], edit_users: [], depositor: 'intruder' }
      expect(compilation.depositor).to eq('001234567')
    end

    it 'accepts string-keyed ACL hashes (controller params shape)' do
      compilation.permissions = { 'read' => ['public'], 'edit' => [], 'edit_users' => ['000000001'] }
      expect(compilation).to be_public
      expect(compilation.edit_users).to eq(['000000001'])
    end

    it 'audited_acl carries the grant keys of the resource concern slice' do
      compilation.publicize
      acl = compilation.audited_acl
      expect(acl.keys).to match_array(Compilation::ACL::AUDITED_KEYS)
      expect(acl[:read]).to eq(['public'])
    end

    # The resource slice audits embargo; Compilations have no embargo
    # attribute, so their rows are the grant keys only.
    it 'audited_acl omits the embargo key the resource slice carries' do
      expect(Permissions::AUDITED_ACL_KEYS - Compilation::ACL::AUDITED_KEYS).to eq([:embargo])
      expect(compilation.audited_acl).not_to have_key(:embargo)
    end
  end
end
