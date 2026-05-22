# frozen_string_literal: true

require 'rails_helper'

# Three named deposit shapes from the gap report; each asserts both the
# resource-level provenance fields and the matching AuditEvent attribution.
RSpec.describe WorkCreator do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  describe 'self-deposit' do
    it 'stamps depositor == proxy_uploader == actor and emits one AuditEvent' do
      expect do
        @work = described_class.call(
          parent_id:      collection.noid,
          proxy_uploader: '000000002',
          actor_nuid:     '000000002'
        )
      end.to change(AuditEvent, :count).by(1)

      expect(@work.depositor).to      eq('000000002')
      expect(@work.proxy_uploader).to eq('000000002')

      ev = AuditEvent.last
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

      ev = AuditEvent.last
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

      ev = AuditEvent.last
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
end
