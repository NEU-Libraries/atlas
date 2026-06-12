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
      expect(CompilationWorkInclusion.where(resource_noid: work.noid)).to be_empty
    end
  end

  describe 'ACL helpers (CompilationPermissions)' do
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

    it 'audited_acl matches the resource concern key set' do
      compilation.publicize
      acl = compilation.audited_acl
      expect(acl.keys).to match_array(Permissions::AUDITED_ACL_KEYS)
      expect(acl[:read]).to eq(['public'])
    end
  end
end
