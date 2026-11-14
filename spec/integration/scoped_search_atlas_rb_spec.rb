# frozen_string_literal: true

require 'rails_helper'

# AtlasRb::Compilation.search, Collection.search and Community.search wrap the
# three scoped search routes. Proven through the live server: the wire shape of
# the filters and facets, the digests and facet counts that come back, the
# state filters that hold even for an admin, the 400 and the 404.
#
# The gem always presents the cerberus bearer token, so the guest cases are in
# spec/requests/scoped_search_spec.rb. Works born from the creators are
# private, so these examples search as admin.
RSpec.describe 'Scoped search via atlas_rb', :atlas_rb_server do
  let(:admin_nuid)    { '000000004' }
  let(:mods_template) { Rails.root.join('spec/fixtures/files/work-mods.xml').read }

  # A finished Work whose MODS carries the given title and genre.
  def work_in(parent, title:, genre: 'Photographs', **attrs)
    created = WorkCreator.call(parent_id: parent.noid)
    Work.find(created.noid).mods_xml = mods_template.sub("What's New</mods:title>", "#{title}</mods:title>")
                                                    .sub('>podcasts<', ">#{genre}<")
    work = Work.find(created.noid)
    work.in_progress = false
    attrs.each { |key, value| work.public_send(:"#{key}=", value) }
    Atlas.persister.save(resource: work)
  end

  # The query string of every request the block sends, off the gem's own
  # instrumentation event, so the spec pins what went over the wire.
  def query_strings
    queries = []
    subscription = ActiveSupport::Notifications.subscribe('request.atlas_rb') do |*args|
      queries << CGI.unescape(ActiveSupport::Notifications::Event.new(*args).payload.url.query.to_s)
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  # community ── collection ── nested
  #           └─ other
  let!(:community)  { CommunityCreator.call }
  let!(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let!(:nested)     { CollectionCreator.call(parent_id: collection.noid) }
  let!(:other)      { CollectionCreator.call(parent_id: community.noid) }

  let!(:photo)       { work_in(collection, title: 'Albatross at sea') }
  let!(:nested_map)  { work_in(nested, title: 'Albatross range', genre: 'Maps') }
  let!(:stray_photo) { work_in(other, title: 'Harbor at dusk') }

  it 'sends filters as f[field][] and facets as facet[]' do
    result = nil
    queries = query_strings do
      result = AtlasRb::Collection.search(collection.noid, filters: { 'genre_ssim' => ['Photographs'] },
                                                           facets: ['genre_ssim'], nuid: admin_nuid)
    end

    expect(queries.first.split('&')).to include('f[genre_ssim][]=Photographs', 'facet[]=genre_ssim')
    expect(result['works'].pluck('noid')).to eq([photo.noid])
    expect(result.dig('facets', 'genre_ssim')).to eq([{ 'value' => 'Photographs', 'count' => 1 }])
    expect(result['works'].first.resource_class).to eq(AtlasRb::Work)
  end

  it 'searches a Community subtree by keyword, with every facet value counted' do
    result = AtlasRb::Community.search(community.noid, q: 'albatross', facets: %w[genre_ssim],
                                                       sort: 'title', nuid: admin_nuid)

    expect(result['works'].pluck('noid')).to eq([photo.noid, nested_map.noid])
    expect(result.dig('facets', 'genre_ssim').pluck('value')).to contain_exactly('Photographs', 'Maps')
    expect(result.dig('pagination', 'total')).to eq(2)
  end

  it "searches a Set's resolved recipe" do
    set = AtlasRb::Compilation.create('Seabirds', nuid: admin_nuid)
    AtlasRb::Compilation.add_included_collection(set['id'], nested.noid, nuid: admin_nuid)
    AtlasRb::Compilation.add_included_work(set['id'], stray_photo.noid, nuid: admin_nuid)

    result = AtlasRb::Compilation.search(set['id'], filters: { 'genre_ssim' => 'Maps' }, nuid: admin_nuid)
    expect(result['works'].pluck('noid')).to eq([nested_map.noid])
    expect(result['facets']).to eq({})
  end

  it 'hides embargoed, in-progress and incomplete Works from an admin' do
    hidden = [
      work_in(collection, title: 'Albatross embargoed', embargo_release_date: 1.year.from_now),
      work_in(collection, title: 'Albatross unfinished', in_progress: true),
      work_in(collection, title: 'Albatross incomplete', incomplete: true)
    ]

    searched = AtlasRb::Collection.search(collection.noid, q: 'albatross', nuid: admin_nuid)
    expect(searched['works'].pluck('noid')).to contain_exactly(photo.noid, nested_map.noid)

    listed = AtlasRb::Resource.descendant_works(collection.noid, nuid: admin_nuid)
    expect(listed['works'].pluck('noid')).to include(*hidden.map(&:noid))
  end

  it "raises ResourceError carrying Atlas's message for a field off the list" do
    expect { AtlasRb::Collection.search(collection.noid, facets: ['depositor_ssi'], nuid: admin_nuid) }
      .to raise_error(AtlasRb::ResourceError) { |e|
        expect(e.status).to eq(400)
        expect(e.message).to include('depositor_ssi')
      }
  end

  it 'returns nil for an unknown id, and for an id of the wrong type' do
    expect(AtlasRb::Collection.search('no-such-collection', nuid: admin_nuid)).to be_nil
    expect(AtlasRb::Collection.search(community.noid, nuid: admin_nuid)).to be_nil
  end
end
