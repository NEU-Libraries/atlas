# frozen_string_literal: true

require 'rails_helper'

# Three named deposit shapes; each asserts both the resource-level provenance
# fields and the matching AuditEvent attribution.
RSpec.describe WorkCreator do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  describe 'self-deposit' do
    it 'stamps depositor == proxy_uploader == actor and emits structural + permissions-grant rows' do
      expect do
        @work = described_class.call(
          parent_id:      collection.noid,
          proxy_uploader: '000000002',
          actor_nuid:     '000000002'
        )
      end.to change(AuditEvent, :count).by(2)

      expect(@work.depositor).to      eq('000000002')
      expect(@work.proxy_uploader).to eq('000000002')

      ev = AuditEvent.find_by(change_type: 'structural')
      expect(ev).to have_attributes(
        actor_nuid:        '000000002',
        on_behalf_of_nuid: nil, # actor == depositor → no proxy attribution
        action:            'create',
        change_type:       'structural',
        event_source:      'controller',
        resource_id:       @work.id.to_s,
        resource_type:     'Work'
      )
    end
  end

  describe 'in-band proxy (depositor explicit, librarian on the keyboard)' do
    it 'stamps the supplied depositor and records the librarian as proxy_uploader' do
      @work = described_class.call(
        parent_id:      collection.noid,
        proxy_uploader: '000000002',           # librarian
        depositor:      '900000001',           # faculty
        actor_nuid:     '000000002'
      )

      expect(@work.depositor).to      eq('900000001')
      expect(@work.proxy_uploader).to eq('000000002')

      ev = AuditEvent.find_by(change_type: 'structural')
      expect(ev.actor_nuid).to        eq('000000002')
      expect(ev.on_behalf_of_nuid).to eq('900000001') # depositor differs → implicit on_behalf_of
    end
  end

  describe 'anonymous batch via collection-default depositor inheritance' do
    let(:anonymous_collection) do
      c = CollectionCreator.call(parent_id: community.noid)
      c.depositor = '000000099'
      Atlas.persister.save(resource: c)
    end

    it 'inherits the collection depositor when none is supplied' do
      @work = described_class.call(
        parent_id:      anonymous_collection.noid,
        proxy_uploader: '000000003', # marcom loader
        actor_nuid:     '000000003'
      )

      expect(@work.depositor).to      eq('000000099') # inherited from collection
      expect(@work.proxy_uploader).to eq('000000003')

      ev = AuditEvent.find_by(change_type: 'structural')
      expect(ev.actor_nuid).to        eq('000000003')
      expect(ev.on_behalf_of_nuid).to eq('000000099') # depositor != actor
    end
  end

  describe 'no provenance kwargs (internal callers like reset.rake / specs)' do
    it 'creates the Work and skips AuditEvent when actor_nuid is absent' do
      expect { @work = described_class.call(parent_id: collection.noid) }
        .not_to change(AuditEvent, :count)
      expect(@work).to be_a(Work)
    end
  end

  describe 'permissions-copy ordering regression' do
    let(:collection_with_depositor) do
      c = CollectionCreator.call(parent_id: community.noid)
      c.depositor = 'inherited_from_collection'
      Atlas.persister.save(resource: c)
    end

    it 'preserves the WorkCreator-supplied proxy_uploader across the parent.permissions copy' do
      @work = described_class.call(
        parent_id:      collection_with_depositor.noid,
        proxy_uploader: 'librarian_stamping_here',
        actor_nuid:     'librarian_stamping_here'
      )

      # The parent.permissions copy lands BEFORE the field stamp; if the
      # ordering ever inverts, the librarian's stamp would be clobbered by
      # the inherited nil/parent value.
      expect(@work.proxy_uploader).to eq('librarian_stamping_here')
    end
  end

  # Acting-as: pure impersonation. The Work must read exactly as if the target
  # deposited it — depositor = target, proxy_uploader null — with the admin
  # captured only in the AuditEvent.
  describe 'acting-as impersonation (On-Behalf-Of present)' do
    it 'stamps depositor = target, leaves proxy_uploader null, and records both principals' do
      expect do
        @work = described_class.call(
          parent_id:         collection.noid,
          depositor:         '900000001',   # target (Cerberus sends this explicitly)
          proxy_uploader:    nil,           # controller sends nil under impersonation
          actor_nuid:        '000000004',   # admin operator
          on_behalf_of_nuid: '900000001'    # target
        )
      end.to change(AuditEvent, :count).by(2)

      expect(@work.depositor).to      eq('900000001')
      expect(@work.proxy_uploader).to be_nil

      ev = AuditEvent.find_by(change_type: 'structural')
      expect(ev).to have_attributes(
        actor_nuid:        '000000004', # admin — the hand on the keyboard, in the trail only
        on_behalf_of_nuid: '900000001', # target — the attribution stamp
        action:            'create'
      )
    end

    it 'nulls an inherited proxy_uploader rather than merely skipping the stamp' do
      # Defeat the parent.permissions copy: a collection carrying a
      # proxy_uploader must not bleed onto an impersonation deposit.
      c = CollectionCreator.call(parent_id: community.noid)
      c.proxy_uploader = 'inherited_proxy'
      c.depositor      = 'inherited_depositor'
      Atlas.persister.save(resource: c)

      @work = described_class.call(
        parent_id:         c.noid,
        depositor:         '900000001',
        actor_nuid:        '000000004',
        on_behalf_of_nuid: '900000001'
      )

      expect(@work.proxy_uploader).to be_nil
      expect(@work.depositor).to      eq('900000001')
    end
  end

  # The ACL a Work is born with — copied from its parent at create — must
  # surface as a permissions audit event, or the meaningful "granted at
  # creation" transition is invisible in Rights history.
  describe 'permissions grant at create' do
    it 'emits an inherited permissions grant naming the parent' do
      # Make the parent public so the inherited grant carries a real read ACL.
      public_collection = CollectionCreator.call(parent_id: community.noid)
      public_collection.publicize
      Atlas.persister.save(resource: public_collection)

      @work = described_class.call(parent_id: public_collection.noid, actor_nuid: '000000004')

      grant = AuditEvent.find_by(action: 'create', change_type: 'permissions')
      expect(grant).not_to be_nil
      expect(grant.resource_id).to                  eq(@work.id.to_s)
      expect(grant.payload['before']).to            eq({})
      expect(grant.payload.dig('after', 'read')).to include('public')
      expect(grant.payload.dig('after', 'edit')).to include(Permissions::STAFF_EDIT_GROUP)
      expect(grant.payload['source']).to            eq('inherited')
      expect(grant.note).to                         eq("inherited from #{public_collection.noid}")
    end

    it 'skips the grant event when no actor is present (internal callers)' do
      expect { described_class.call(parent_id: collection.noid) }
        .not_to change(AuditEvent, :count)
    end
  end
end
