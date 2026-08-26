# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MODSPreloader do
  after { Atlas.persister.wipe! }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let!(:titled)    { WorkCreator.call(parent_id: collection.noid) }
  # Built through the persister, not WorkCreator: a creator seeds the MODS
  # template, so this is how a resource ends up with no access copy at all.
  let!(:untitled)  { Atlas.persister.save(resource: Work.new(a_member_of: collection.id)) }

  before { set_mods_primary_title!(titled, 'Preloaded') }

  it 'seeds the memo so a page of rows costs one metadata_mods query' do
    rows = [Work.find(titled.noid), Work.find(untitled.noid)]

    queries = count_queries do
      described_class.call(resources: rows)
      rows.each { |row| row.decorate.plain_title }
    end

    expect(queries.grep(/metadata_mods/).size).to eq(1)
  end

  it 'seeds the row it found with its own access copy' do
    row = Work.find(titled.noid)
    described_class.call(resources: [row])

    expect(row.decorate.plain_title).to eq('Preloaded')
  end

  # A resource with no access copy is the case the unbatched reader missed: it
  # memoized nothing and re-queried, which would undo the batch.
  it 'seeds nil for a row with no access copy, and does not re-query it' do
    row = Work.find(untitled.noid)
    described_class.call(resources: [row])

    queries = count_queries { 2.times { row.decorate.plain_title } }

    expect(row.mods).to be_nil
    expect(queries.grep(/metadata_mods/)).to be_empty
  end

  it 'touches the database for an empty list not at all' do
    expect(count_queries { described_class.call(resources: []) }).to be_empty
  end
end
