# frozen_string_literal: true

require 'rails_helper'

# The admin tombstone registry reads these fields straight from Solr, so the
# claims are pinned against the stored document rather than the indexer hash.
RSpec.describe 'A tombstoned resource in the Solr document' do
  let(:community)  { Atlas.persister.save(resource: Community.new) }
  let(:collection) { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
  let(:nested)     { Atlas.persister.save(resource: Collection.new(a_member_of: collection.id)) }

  def tombstoned(resource, at:)
    resource.tombstone(by: '000000002')
    resource.tombstoned_at = at
    Atlas.persister.save(resource: resource)
  end

  def matches(filter)
    Atlas.index_adapter.connection
         .get('select', params: { q: '*:*', fq: filter, fl: 'alternate_ids_ssim', rows: 10 })
         .dig('response', 'docs').flat_map { |doc| doc['alternate_ids_ssim'].map { |id| id.delete_prefix('id-') } }
  end

  it 'stores the withdrawal time as a Solr date' do
    saved = tombstoned(nested, at: Time.utc(2026, 10, 7, 19, 22, 34))

    expect(IndexDocumentQuery.call(saved.noid)['tombstoned_at_dtsi']).to eq('2026-10-07T19:22:34Z')
  end

  it 'filters by withdrawal date as a date range' do
    inside  = tombstoned(nested, at: Time.utc(2026, 10, 7, 12))
    outside = tombstoned(Atlas.persister.save(resource: Collection.new(a_member_of: collection.id)),
                         at: Time.utc(2026, 10, 9, 12))

    found = matches('tombstoned_at_dtsi:[2026-10-01T00:00:00Z TO 2026-10-08T00:00:00Z}')

    expect(found).to include(inside.noid)
    expect(found).not_to include(outside.noid)
  end

  it 'keeps the ancestor chain on a tombstoned container' do
    saved = tombstoned(nested, at: Time.current)

    expect(IndexDocumentQuery.call(saved.noid)['ancestor_ids_ssim'])
      .to contain_exactly(collection.noid, community.noid)
  end
end
