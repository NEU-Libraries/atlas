# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Relationships do
  describe '#ancestors' do
    let!(:community)  { Atlas.persister.save(resource: Community.new) }
    let!(:collection) { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
    let!(:nested)     { Atlas.persister.save(resource: Collection.new(a_member_of: collection.id)) }

    it 'walks the chain to the root (root-first), as [noid, class] pairs' do
      expect(nested.ancestors).to eq([[community.noid, 'Community'], [collection.noid, 'Collection']])
    end

    it 'returns [] for a top-level resource' do
      expect(community.ancestors).to eq([])
    end

    # Corrupt the tree via the Postgres-only persister so the AncestryIndexer
    # (which runs ancestors at index time, and would itself raise the guard)
    # doesn't fire — isolating the walk under test. The indexer-time guard is
    # exercised separately; here we assert the walk raises rather than hangs.
    let(:pg) { Valkyrie::MetadataAdapter.find(:postgres).persister }

    it 'raises AncestorError on a cycle instead of recursing forever' do
      # 2-cycle: community now points at collection, which points back at it.
      community.a_member_of = collection.id
      pg.save(resource: community)

      expect { collection.ancestors }.to raise_error(Exceptions::AncestorError)
    end

    it 'raises AncestorError on a direct self-parent loop' do
      collection.a_member_of = collection.id
      pg.save(resource: collection)

      expect { collection.ancestors }.to raise_error(Exceptions::AncestorError)
    end
  end

  describe '#ancestor_chain' do
    # Use the Creator services so each resource gets its descriptive-metadata
    # FileSet — `plain_title=` writes through MODS, which needs that FileSet.
    let!(:community)  { CommunityCreator.call }
    let!(:collection) { CollectionCreator.call(parent_id: community.noid) }
    let!(:work)       { WorkCreator.call(parent_id: collection.noid) }

    before do
      community.plain_title  = 'Root Community'
      collection.plain_title = 'Parent Collection'
    end

    it 'returns root-first {noid, klass, title} nodes carrying each ancestor title' do
      expect(work.ancestor_chain).to eq([
                                          { noid: community.noid,  klass: 'Community',  title: 'Root Community' },
                                          { noid: collection.noid, klass: 'Collection', title: 'Parent Collection' }
                                        ])
    end

    it 'returns [] for a top-level resource' do
      expect(community.ancestor_chain).to eq([])
    end

    it 'raises AncestorError on a cycle (same guard as #ancestors)' do
      pg = Valkyrie::MetadataAdapter.find(:postgres).persister
      community.a_member_of = collection.id
      pg.save(resource: community)

      expect { collection.ancestor_chain }.to raise_error(Exceptions::AncestorError)
    end
  end

  describe '#descendant_collections' do
    let!(:community)  { Atlas.persister.save(resource: Community.new) }
    let!(:collection) { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
    let!(:nested)     { Atlas.persister.save(resource: Collection.new(a_member_of: collection.id)) }

    it 'delegates to DescendantCollectionsQuery' do
      expect(collection.descendant_collections.map(&:noid)).to contain_exactly(nested.noid)
    end
  end
end
