# frozen_string_literal: true

require 'rails_helper'

# AtlasRb::Resource.descendant_works wraps GET /resources/:id/descendant_works —
# every Work beneath a container, at any depth, flattened, gated, and paginated
# (the structural counterpart to /compilations/:id/contents). Proven end-to-end
# through the live server: URL shape, transitive flattening, the structural-vs-
# linked distinction (?include_linked), Solr-side pagination, and the 404 → nil
# mapping.
#
# The gem always presents the cerberus bearer token, so the guest/public ACL
# matrix is covered by the request specs (spec/requests/resources_spec.rb);
# works born from the creators are private (empty read_groups), so resolution
# is asserted as admin, who skips the gated-discovery ACL filter.
RSpec.describe 'Descendant works via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { '000000004' }

  # community ── collection ── nested ── nested_work
  #           │             └─ work_a, work_b
  #           └─ other ── stray_work, linked_work (linked into collection)
  #
  # let! (not let): the whole tree must exist before the Solr query runs — a
  # lazily-built Work referenced only in an assertion would be created after.
  let!(:community)  { CommunityCreator.call }
  let!(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let!(:nested)     { CollectionCreator.call(parent_id: collection.noid) }
  let!(:other)      { CollectionCreator.call(parent_id: community.noid) }

  let!(:work_a)      { WorkCreator.call(parent_id: collection.noid) }
  let!(:work_b)      { WorkCreator.call(parent_id: collection.noid) }
  let!(:nested_work) { WorkCreator.call(parent_id: nested.noid) }
  let!(:stray_work)  { WorkCreator.call(parent_id: other.noid) }
  let!(:linked_work) do
    WorkCreator.call(parent_id: other.noid).tap do |w|
      AtlasRb::Work.add_linked_member(w.noid, collection.noid, nuid: admin_nuid)
    end
  end

  it 'flattens the subtree transitively (structural membership only)' do
    result = AtlasRb::Resource.descendant_works(collection.noid, nuid: admin_nuid)

    expect(result['works'].pluck('noid'))
      .to contain_exactly(work_a.noid, work_b.noid, nested_work.noid)
    expect(result['works'].pluck('noid')).not_to include(stray_work.noid, linked_work.noid)
    expect(result.dig('pagination', 'total')).to eq(3)
    expect(result['works'].first['klass']).to eq('Work')
  end

  it 'unions linked members when include_linked: true' do
    result = AtlasRb::Resource.descendant_works(collection.noid, include_linked: true, nuid: admin_nuid)

    expect(result['works'].pluck('noid'))
      .to contain_exactly(work_a.noid, work_b.noid, nested_work.noid, linked_work.noid)
    expect(result.dig('pagination', 'total')).to eq(4)
  end

  it 'paginates Solr-side (page / per_page)' do
    page1 = AtlasRb::Resource.descendant_works(collection.noid, page: 1, per_page: 2, nuid: admin_nuid)
    expect(page1['works'].length).to eq(2)
    expect(page1['pagination'])
      .to include('total' => 3, 'page' => 1, 'per_page' => 2, 'pages' => 2)

    page2 = AtlasRb::Resource.descendant_works(collection.noid, page: 2, per_page: 2, nuid: admin_nuid)
    expect(page2['works'].length).to eq(1)
    expect((page1['works'] + page2['works']).pluck('noid').uniq.length).to eq(3)
  end

  it 'returns nil for an unknown id (404)' do
    expect(AtlasRb::Resource.descendant_works('no-such-resource', nuid: admin_nuid)).to be_nil
  end
end
