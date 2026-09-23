# frozen_string_literal: true

require 'rails_helper'

# AtlasRb::Resource.search wraps GET /resources/search. Proven end-to-end
# through the live server: the query string it builds, the envelope it returns,
# type narrowing, pagination, and a 400 surfacing as ResourceError.
#
# Asserted as admin, who skips the read gate. Who finds what is covered by
# spec/requests/search_filters_spec.rb.
RSpec.describe 'Catalog search via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { '000000004' }

  let!(:community)  { CommunityCreator.call }
  let!(:collection) { CollectionCreator.call(parent_id: community.noid) }

  # let!: every Work must be indexed before the search runs.
  let!(:hits) { Array.new(3) { |i| titled_work("Quokka field notes #{i}") } }
  let!(:miss) { titled_work('Unrelated survey') }

  def titled_work(title)
    work = WorkCreator.call(parent_id: collection.noid)
    Work.find(work.noid).mods_xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <mods:mods xmlns:mods="http://www.loc.gov/mods/v3">
        <mods:titleInfo usage="primary"><mods:title>#{title}</mods:title></mods:titleInfo>
      </mods:mods>
    XML
    Atlas.persister.save(resource: Work.find(work.noid))
  end

  it 'finds Works by a word in the title and returns the envelope' do
    result = AtlasRb::Resource.search('quokka', nuid: admin_nuid)

    expect(result.results.map(&:noid)).to match_array(hits.map(&:noid))
    expect(result.results.map(&:klass).uniq).to eq(['Work'])
    expect(result.pagination.total).to eq(3)
  end

  it 'lets class_for load a hit as its full resource' do
    hit = AtlasRb::Resource.search('quokka', nuid: admin_nuid).results.first

    expect(AtlasRb::Resource.class_for(hit.klass).find(hit.noid, nuid: admin_nuid)).to be_present
  end

  it 'narrows to one type' do
    result = AtlasRb::Resource.search(nil, type: 'Collection', nuid: admin_nuid)

    expect(result.results.map(&:noid)).to include(collection.noid)
    expect(result.results.map(&:klass).uniq).to eq(['Collection'])
  end

  it 'paginates' do
    page1 = AtlasRb::Resource.search('quokka', page: 1, per_page: 2, nuid: admin_nuid)
    page2 = AtlasRb::Resource.search('quokka', page: 2, per_page: 2, nuid: admin_nuid)

    expect(page1.pagination.to_h).to include('total' => 3, 'page' => 1, 'per_page' => 2, 'pages' => 2)
    expect((page1.results + page2.results).map(&:noid)).to match_array(hits.map(&:noid))
  end

  it 'raises ResourceError with the 400 for an unknown type' do
    expect { AtlasRb::Resource.search('quokka', type: 'Blob', nuid: admin_nuid) }
      .to raise_error(AtlasRb::ResourceError) { |e| expect(e.status).to eq(400) }
  end
end
