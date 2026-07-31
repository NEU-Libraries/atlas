# frozen_string_literal: true

require 'rails_helper'

# The two rules that need context Permissions#permissions= doesn't have: the
# structural parent (containment) and the acting user (grant removal). Both are
# exercised end-to-end over HTTP in spec/requests/permissions_write_rules_spec.rb;
# this file pins the predicate behaviour, including shapes that are awkward to
# drive through a controller.
RSpec.describe PermissionsWriteGuard do
  after { Atlas.persister.wipe! }

  let(:archives) { 'northeastern:drs:library:archives' }
  let(:marcom)   { 'northeastern:drs:library:marcom' }

  def build_user(role:, groups: [])
    User.new(role: role, nuid: '000000777', groups: groups)
  end

  # Removal-exempt, so the containment examples below isolate that one rule.
  let(:operator) { build_user(role: :admin) }

  def public_root
    community = CommunityCreator.call
    community.publicize
    Atlas.persister.save(resource: community)
  end

  def restricted_root(read:)
    community = CommunityCreator.call
    community.read_groups = read
    Atlas.persister.save(resource: community)
  end

  describe 'containment against the parent' do
    it 'allows a read audience that is a subset of the parent’s' do
      collection = CollectionCreator.call(parent_id: restricted_root(read: [archives, marcom]).noid)

      result = described_class.call(resource: collection, actor: operator, incoming: { 'read' => [archives] })

      expect(result['read']).to eq([archives])
    end

    it 'allows anything under a public parent' do
      collection = CollectionCreator.call(parent_id: public_root.noid)

      expect(described_class.call(resource: collection, actor: operator,
                                  incoming: { 'read' => ['public'] })['read']).to eq(['public'])
    end

    it 'refuses a public read under a restricted parent' do
      collection = CollectionCreator.call(parent_id: restricted_root(read: [archives]).noid)

      expect { described_class.call(resource: collection, actor: operator, incoming: { 'read' => ['public'] }) }
        .to raise_error(Exceptions::PermissionsError) { |e| expect(e.code).to eq(:visibility_exceeds_parent) }
    end

    it 'refuses a group the parent does not grant' do
      collection = CollectionCreator.call(parent_id: restricted_root(read: [archives]).noid)

      expect do
        described_class.call(resource: collection, actor: operator, incoming: { 'read' => [archives, marcom] })
      end.to raise_error(Exceptions::PermissionsError)
    end

    it 'allows narrowing to private regardless of the parent' do
      collection = CollectionCreator.call(parent_id: restricted_root(read: [archives]).noid)

      expect(described_class.call(resource: collection, actor: operator, incoming: { 'read' => [] })['read'])
        .to eq([])
    end

    it 'leaves a parentless root Community unconstrained' do
      community = CommunityCreator.call

      expect(described_class.call(resource: community, actor: operator,
                                  incoming: { 'read' => ['public'] })['read']).to eq(['public'])
    end

    # Only the read axis is contained: an edit grant is not a discovery leak,
    # and the rule the reports specify is about visibility.
    it 'does not constrain edit groups against the parent' do
      collection = CollectionCreator.call(parent_id: restricted_root(read: [archives]).noid)

      result = described_class.call(resource: collection, actor: operator,
                                    incoming: { 'read' => [], 'edit' => [marcom] })

      expect(result['edit']).to eq([marcom])
    end
  end

  describe 'grant removal' do
    # Both groups granted read and edit. STAFF_EDIT_GROUP rides along on every
    # resource (the setter re-prepends it unconditionally), so edit assertions
    # below speak to archives/marcom only.
    let(:collection) do
      c = CollectionCreator.call(parent_id: public_root.noid)
      c.permissions = { read: ['public', archives], edit: [archives, marcom], edit_users: [] }
      Atlas.persister.save(resource: c)
    end

    it 'merges back a group the actor is not a member of' do
      actor  = build_user(role: :standard, groups: [marcom])
      result = described_class.call(resource: collection, actor: actor,
                                    incoming: { 'read' => ['public'], 'edit' => [marcom] })

      expect(result['read']).to contain_exactly('public', archives)
      expect(result['edit']).to include(archives, marcom)
    end

    it 'lets the actor remove a group they belong to' do
      actor  = build_user(role: :standard, groups: [archives])
      result = described_class.call(resource: collection, actor: actor,
                                    incoming: { 'read' => ['public'], 'edit' => [marcom] })

      expect(result['read']).to contain_exactly('public')
      expect(result['edit']).to     include(marcom)
      expect(result['edit']).not_to include(archives)
    end

    # `public` is a visibility token, not a group — nobody is a member of it, so
    # treating it like one would freeze a resource permanently open and take the
    # depositor's own visibility away from them.
    it 'always allows removing the public token' do
      actor  = build_user(role: :standard, groups: [archives])
      result = described_class.call(resource: collection, actor: actor,
                                    incoming: { 'read' => [], 'edit' => [archives, marcom] })

      expect(result['read']).to eq([])
    end

    it 'exempts an admin' do
      result = described_class.call(resource: collection, actor: build_user(role: :admin),
                                    incoming: { 'read' => ['public'], 'edit' => [] })

      expect(result['read']).to eq(['public'])
      expect(result['edit']).to eq([])
    end

    it 'exempts the devolved-admin tier' do
      actor  = build_user(role: :privileged, groups: [Permissions::ADMIN_GROUP])
      result = described_class.call(resource: collection, actor: actor,
                                    incoming: { 'read' => ['public'], 'edit' => [] })

      expect(result['edit']).to eq([])
    end

    it 'does not constrain additions' do
      actor  = build_user(role: :standard, groups: [archives, marcom])
      result = described_class.call(resource: collection, actor: actor,
                                    incoming: { 'read' => ['public', archives],
                                                'edit' => [archives, marcom, 'northeastern:drs:new'] })

      expect(result['edit']).to include('northeastern:drs:new')
    end

    # edit_users carries individual NUIDs, not groups; the rule is about group
    # membership and says nothing about them.
    it 'leaves edit_users alone' do
      c = CollectionCreator.call(parent_id: public_root.noid)
      c.permissions = { read: ['public'], edit: [], edit_users: ['000000999'] }
      c = Atlas.persister.save(resource: c)

      result = described_class.call(resource: c, actor: build_user(role: :standard),
                                    incoming: { 'read' => ['public'], 'edit' => [], 'edit_users' => [] })

      expect(result['edit_users']).to eq([])
    end
  end
end
