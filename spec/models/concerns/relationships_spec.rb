# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Relationships do
  describe '#ancestor_noids' do
    let!(:community)  { Atlas.persister.save(resource: Community.new) }
    let!(:collection) { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
    let!(:nested)     { Atlas.persister.save(resource: Collection.new(a_member_of: collection.id)) }

    it 'walks the chain to the root (root-first), as bare noids' do
      expect(nested.ancestor_noids).to eq([community.noid, collection.noid])
    end

    it 'returns [] for a top-level resource' do
      expect(community.ancestor_noids).to eq([])
    end

    # Corrupt the tree via the Postgres-only persister so the AncestryIndexer
    # (which runs the walk at index time, and would itself raise the guard)
    # doesn't fire — isolating the walk under test. The indexer-time guard is
    # exercised separately; here we assert the walk raises rather than hangs.
    let(:pg) { Valkyrie::MetadataAdapter.find(:postgres).persister }

    it 'raises AncestorError on a cycle instead of recursing forever' do
      # 2-cycle: community now points at collection, which points back at it.
      community.a_member_of = collection.id
      pg.save(resource: community)

      expect { collection.ancestor_noids }.to raise_error(Exceptions::AncestorError)
    end

    it 'raises AncestorError on a direct self-parent loop' do
      collection.a_member_of = collection.id
      pg.save(resource: collection)

      expect { collection.ancestor_noids }.to raise_error(Exceptions::AncestorError)
    end
  end

  describe '#ancestors' do
    # Use the Creator services so each resource gets its descriptive-metadata
    # FileSet — seeding a title writes through MODS, which needs that FileSet.
    let!(:community)  { CommunityCreator.call }
    let!(:collection) { CollectionCreator.call(parent_id: community.noid) }
    let!(:work)       { WorkCreator.call(parent_id: collection.noid) }

    before do
      set_mods_primary_title!(community,  'Root Community')
      set_mods_primary_title!(collection, 'Parent Collection')
    end

    it 'returns root-first nodes carrying each ancestor title, unflagged in an ordinary tree' do
      expect(work.ancestors).to eq([
                                     { noid: community.noid, klass: 'Community', title: 'Root Community',
                                       system_container: false, personal_root: false },
                                     { noid: collection.noid, klass: 'Collection', title: 'Parent Collection',
                                       system_container: false, personal_root: false }
                                   ])
    end

    it 'flags the People Community and the personal root, and nothing below them' do
      root      = PersonalRootCreator.call(nuid: '001234567')
      workspace = CollectionCreator.call(parent_id: root.noid)
      deposit   = WorkCreator.call(parent_id: workspace.noid)

      flags = deposit.ancestors.map { |a| a.slice(:noid, :system_container, :personal_root) }
      expect(flags).to eq([
                            { noid: root.parent.noid, system_container: true,  personal_root: false },
                            { noid: root.noid,        system_container: false, personal_root: true },
                            { noid: workspace.noid,   system_container: false, personal_root: false }
                          ])
    end

    it 'returns [] for a top-level resource' do
      expect(community.ancestors).to eq([])
    end

    it 'raises AncestorError on a cycle (same guard as #ancestor_noids)' do
      pg = Valkyrie::MetadataAdapter.find(:postgres).persister
      community.a_member_of = collection.id
      pg.save(resource: community)

      expect { collection.ancestors }.to raise_error(Exceptions::AncestorError)
    end

    it 'reads every ancestor title in one MODS query, however deep the chain' do
      nested = CollectionCreator.call(parent_id: CollectionCreator.call(parent_id: collection.noid).noid)
      deep   = WorkCreator.call(parent_id: nested.noid)
      mods_reads = ->(resource) { count_queries { resource.ancestors }.grep(/metadata_mods/).size }

      expect(mods_reads.call(deep)).to eq(mods_reads.call(work))
    end

    it 'composes each title exactly as the ancestor\'s own plain_title does' do
      doc  = NEU::MODS::Document.parse(collection.mods_xml)
      info = doc.primary_title_info
      { 'nonSort' => 'The', 'subTitle' => 'a subtitle', 'partNumber' => 'Part 2' }.each do |name, text|
        node = Nokogiri::XML::Node.new(name, info.document)
        node.namespace = info.namespace
        node.content = text
        info.add_child(node)
      end
      collection.mods_xml = doc.to_xml

      title = work.ancestors.last[:title]
      expect(title).to eq(Collection.find(collection.noid).decorate.plain_title)
      expect(title).to include('The', 'a subtitle', 'Part 2')
    end

    it 'gives an ancestor with no MODS row an empty title' do
      Metadata::MODS.where(valkyrie_id: collection.noid).delete_all

      expect(work.ancestors.last[:title]).to eq('')
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
