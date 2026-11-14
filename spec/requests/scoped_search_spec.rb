# frozen_string_literal: true

require 'swagger_helper'

# GET /compilations/:id/search, /collections/:id/search and
# /communities/:id/search: a keyword, filters and facets within one scope. The
# container routes return the Collections beneath the scope beside its Works.
# The rswag blocks drive the OpenAPI entries; the describe blocks below them pin
# who sees what, because every rule there applies to admins too.
RSpec.describe 'Scoped search', type: :request do
  let(:mods_template) { Rails.root.join('spec/fixtures/files/work-mods.xml').read }

  after { Atlas.persister.wipe! }

  def public_container(parent)
    container = CollectionCreator.call(parent_id: parent.noid)
    container.publicize
    Atlas.persister.save(resource: container)
  end

  # A finished, public Work whose MODS carries the given title, genre and year.
  # attrs override the Work's state after the MODS lands.
  def work_in(parent, title:, genre: 'Photographs', year: '2017', **attrs)
    created = WorkCreator.call(parent_id: parent.noid)
    Work.find(created.noid).mods_xml = mods_template
                                       .sub("What's New</mods:title>", "#{title}</mods:title>")
                                       .sub('>podcasts<', ">#{genre}<")
                                       .sub('2017-09-19</mods:dateCreated>', "#{year}-09-19</mods:dateCreated>")
    work = Work.find(created.noid)
    work.in_progress = false
    work.publicize
    attrs.each { |key, value| work.public_send(:"#{key}=", value) }
    Atlas.persister.save(resource: work)
  end

  # community ── collection ── nested
  #           └─ other
  let!(:community)  { public_community! }
  let!(:collection) { public_container(community) }
  let!(:nested)     { public_container(collection) }
  let!(:other)      { public_container(community) }

  let!(:albatross_photo) { work_in(collection, title: 'Albatross at sea') }
  let!(:harbor_photo)    { work_in(nested, title: 'Harbor at dusk', year: '1998') }
  let!(:albatross_map)   { work_in(collection, title: 'Albatross range', genre: 'Maps') }
  let!(:stray_photo)     { work_in(other, title: 'Albatross ashore') }

  def noids(response)
    response.parsed_body['results'].pluck('noid')
  end

  shared_context 'with a Set over the collection' do
    let(:owner) do
      User.create!(email: 'owner@example.com', password: SecureRandom.hex(16),
                   nuid: '000000002', role: :standard)
    end
    let!(:compilation) do
      Compilation.create!(title: 'Seabirds', depositor: owner.nuid).tap do |set|
        set.publicize
        set.save!
        set.collection_inclusions.create!(resource_noid: collection.noid)
      end
    end
  end

  # One block per route. Each documents the same parameters, so they cannot
  # drift apart in the generated documents.
  def self.search_parameters(include_linked:)
    parameter name: :q, in: :query, type: :string, required: false,
              description: 'Search text. Omit to list the whole scope.'
    parameter name: :f, in: :query, required: false, style: :deepObject, explode: true,
              schema:      { type: :object, additionalProperties: { type: :array, items: { type: :string } } },
              description: 'Filters, as `f[field][]=value`. Values in one field match any; fields must all ' \
                           "match. Fields: #{ScopedSearch::FACET_FIELDS.join(', ')}."
    parameter name: :sort, in: :query, required: false,
              schema:      { type: :string, enum: ScopedSearch::SORTS.keys },
              description: '`relevance`, `title` (A to Z) or `date` (newest first). Omit for relevance when `q` ' \
                           'is given, and a stable order otherwise.'
    facet_parameters
    paginated per_page: true, shape: :search
    return unless include_linked

    parameter name: :include_linked, in: :query, type: :boolean, required: false,
              description: 'Also search Works linked into the subtree from elsewhere; false by default'
  end

  def self.facet_parameters
    parameter name: 'facet[]', in: :query, required: false, style: :form, explode: true,
              schema:      { type: :array, items: { type: :string, enum: ScopedSearch::FACET_FIELDS } },
              description: 'The fields to count values for. Omit for no counts.'
    parameter name: :facet_limit, in: :query, required: false,
              schema:      { type: :integer, minimum: 1, maximum: ScopedSearch::MAX_FACET_LIMIT },
              description: "Values per facet, at most #{ScopedSearch::MAX_FACET_LIMIT}. A value that is not a " \
                           "positive number gives #{ScopedSearch::DEFAULT_FACET_LIMIT}."
  end

  def self.collection_rules
    <<~DESC
      Each row's `klass` is `Work` or `Collection`. The Collections are those at
      any depth beneath the scope, never the scope itself, and never a tombstoned,
      featured, personal-root or system Collection. A Collection carries none of
      the filter fields' Work values, so a filter on `f` drops every Collection.
    DESC
  end

  def self.search_rules
    <<~DESC
      Gated per row to what the caller may read, as on
      `GET /resources/{id}/descendant_works`. A caller with no token sees public
      rows only. Every caller, admins included, never sees a tombstoned,
      embargoed, in-progress or incomplete Work here.

      `facet[]` and the keys of `f` take only the listed fields; any other answers
      `400`, and so does an unknown `sort`. Facet counts cover the whole result,
      within the scope and after the filters, not only this page.
    DESC
  end

  path '/compilations/{id}/search' do
    parameter name: :id, in: :path, type: :string, description: 'Compilation NOID'

    get 'Search within a compilation' do
      tags 'Compilations'
      response_texts(
        '200' => 'One page of the matching Works the Compilation resolves to, with the requested facet counts.',
        '400' => 'A facet or filter names a field off the list, or `sort` is unknown.',
        '403' => 'The caller may not read this Compilation, as when a guest asks for a private one.',
        '404' => 'No Compilation has that NOID.'
      )
      produces 'application/json'
      description "Searches the Works that `GET /compilations/{id}/contents` resolves to.\n\n#{search_rules}"
      search_parameters(include_linked: false)
      include_context 'with a Set over the collection'

      let(:id)          { compilation.noid }
      let(:q)           { 'albatross' }
      let(:f)           { nil }
      let(:'facet[]')   { %w[genre_ssim] }
      let(:facet_limit) { nil }
      let(:sort)        { nil }
      let(:page)        { nil }
      let(:per_page)    { nil }

      response '200', 'matching Works in the Set, with genre counts' do
        schema '$ref' => '#/components/schemas/ScopedSearchResults'
        run_test! do |response|
          expect(noids(response)).to contain_exactly(albatross_photo.noid, albatross_map.noid)
          expect(response.parsed_body.dig('facets', 'genre_ssim'))
            .to contain_exactly({ 'value' => 'Photographs', 'count' => 1 }, { 'value' => 'Maps', 'count' => 1 })
        end
      end

      response '400', 'a facet off the list' do
        let(:'facet[]') { %w[depositor_ssi] }
        run_test! do |response|
          expect(response.parsed_body['error']).to include('depositor_ssi')
        end
      end

      response '404', 'unknown id' do
        let(:id) { 'does-not-exist' }
        run_test!
      end
    end
  end

  path '/collections/{id}/search' do
    parameter name: :id, in: :path, type: :string, description: 'Collection NOID'

    get 'Search within a collection' do
      tags 'Collections'
      response_texts(
        '200' => 'One page of the matching Works and Collections beneath the Collection, with the requested ' \
                 'facet counts.',
        '400' => 'A facet or filter names a field off the list, or `sort` is unknown.',
        '404' => 'No Collection has that NOID.',
        '410' => 'The Collection is tombstoned. An admin or delegated admin gets the full Collection record; everyone ' \
                 'else gets a stub.'
      )
      produces 'application/json'
      description "Searches every Work and Collection beneath the Collection, at any depth.\n\n" \
                  "#{collection_rules}\n#{search_rules}"
      search_parameters(include_linked: true)

      let(:id)             { collection.noid }
      let(:q)              { nil }
      let(:f)              { { 'genre_ssim' => ['Photographs'] } }
      let(:'facet[]')      { %w[pub_date_ssim] }
      let(:facet_limit)    { nil }
      let(:sort)           { 'title' }
      let(:page)           { nil }
      let(:per_page)       { nil }
      let(:include_linked) { nil }

      response '200', 'the subtree filtered to one genre, with year counts' do
        schema '$ref' => '#/components/schemas/ScopedSearchResults'
        run_test! do |response|
          expect(noids(response)).to eq([albatross_photo.noid, harbor_photo.noid])
          expect(response.parsed_body.dig('facets', 'pub_date_ssim').pluck('value')).to contain_exactly('2017', '1998')
        end
      end

      response '400', 'a filter off the list' do
        let(:f) { { 'read_access_group_ssim' => ['public'] } }
        run_test!
      end

      response '404', 'unknown id' do
        let(:id) { 'does-not-exist' }
        run_test!
      end

      tombstoned_record_responses(full: 'Collection', withheld: 'CollectionTombstone') do
        let(:id) { tombstoned_public_container!(Collection).noid }
      end
    end
  end

  path '/communities/{id}/search' do
    parameter name: :id, in: :path, type: :string, description: 'Community NOID'

    get 'Search within a community' do
      tags 'Communities'
      response_texts(
        '200' => 'One page of the matching Works and Collections beneath the Community, with the requested ' \
                 'facet counts.',
        '400' => 'A facet or filter names a field off the list, or `sort` is unknown.',
        '404' => 'No Community has that NOID.',
        '410' => 'The Community is tombstoned. An admin or delegated admin gets the full Community record; everyone ' \
                 'else gets a stub.'
      )
      produces 'application/json'
      description "Searches every Work and Collection beneath the Community, at any depth.\n\n" \
                  "#{collection_rules}\n#{search_rules}"
      search_parameters(include_linked: true)

      let(:id)             { community.noid }
      let(:q)              { 'albatross' }
      let(:f)              { nil }
      let(:'facet[]')      { nil }
      let(:facet_limit)    { nil }
      let(:sort)           { nil }
      let(:page)           { nil }
      let(:per_page)       { nil }
      let(:include_linked) { nil }

      response '200', 'matching Works anywhere beneath the Community' do
        schema '$ref' => '#/components/schemas/ScopedSearchResults'
        run_test! do |response|
          expect(noids(response)).to contain_exactly(albatross_photo.noid, albatross_map.noid, stray_photo.noid)
          expect(response.parsed_body['facets']).to eq({})
        end
      end

      response '400', 'an unknown sort' do
        let(:sort) { 'id desc' }
        run_test!
      end

      response '404', 'unknown id' do
        let(:id) { 'does-not-exist' }
        run_test!
      end

      tombstoned_record_responses(full: 'Community', withheld: 'CommunityTombstone') do
        let(:id) { tombstoned_public_container!(Community).noid }
      end
    end
  end

  describe 'what a search finds', default_auth: false do
    let!(:guest_user) do
      User.create!(email: 'guest@example.com', password: SecureRandom.hex(16), role: :guest)
    end

    def search(path, **params)
      get path, params: params, headers: signed_auth_headers(nil)
      expect(response).to have_http_status(:ok)
      response.parsed_body
    end

    def titled_container(parent, title, **creator_attrs)
      created = CollectionCreator.call(parent_id: parent.noid, **creator_attrs)
      Collection.find(created.noid).mods_xml = Rails.root.join('spec/fixtures/files/collection-mods.xml').read
                                                    .sub('Test Collection</mods:title>', "#{title}</mods:title>")
      container = Collection.find(created.noid)
      container.publicize
      Atlas.persister.save(resource: container)
    end

    def collection_noids(body)
      body['results'].select { |row| row['klass'] == 'Collection' }.pluck('noid')
    end

    it 'lists the whole scope for a blank q' do
      body = search("/collections/#{collection.noid}/search")
      expect(body['results'].pluck('noid'))
        .to contain_exactly(albatross_photo.noid, harbor_photo.noid, albatross_map.noid, nested.noid)
      expect(body['pagination']).to include('total' => 4, 'page' => 1)
    end

    it 'returns the Collections beneath a Community or a Collection, never the scope itself' do
      community_body = search("/communities/#{community.noid}/search")
      expect(collection_noids(community_body)).to contain_exactly(collection.noid, nested.noid, other.noid)
      expect(community_body['results'].pluck('noid')).not_to include(community.noid)

      expect(collection_noids(search("/collections/#{collection.noid}/search"))).to eq([nested.noid])
    end

    it 'matches a Collection by its title' do
      colonies = titled_container(nested, 'Albatross colonies')
      body = search("/communities/#{community.noid}/search", q: 'albatross')
      expect(body['results'].find { |row| row['noid'] == colonies.noid })
        .to include('klass' => 'Collection', 'title' => 'Albatross colonies', 'creators' => [], 'embargoed' => false)
    end

    it 'drops every Collection once a filter applies' do
      body = search("/communities/#{community.noid}/search", f: { genre_ssim: %w[Photographs Maps] })
      expect(body['results'].pluck('klass').uniq).to eq(['Work'])
    end

    it 'hides a private Collection from a guest, and tombstoned and featured ones from an admin too' do
      private_one = titled_container(collection, 'Albatross private').tap do |c|
        c.read_groups = []
        Atlas.persister.save(resource: c)
      end
      tombstoned = tombstoned!(titled_container(collection, 'Albatross tombstoned'))
      featured   = titled_container(community, 'Albatross featured', featured: true)

      expect(collection_noids(search("/communities/#{community.noid}/search", q: 'albatross'))).to be_empty

      get "/communities/#{community.noid}/search",
          params: { q: 'albatross' }, headers: signed_auth_headers(ensure_default_admin!.nuid)
      expect(collection_noids(response.parsed_body)).to eq([private_one.noid])
      expect(response.parsed_body['results'].pluck('noid')).not_to include(tombstoned.noid, featured.noid)
    end

    it 'keeps the Compilation route and descendant_works to Works' do
      set = Compilation.create!(title: 'Seabirds', depositor: '000000002').tap do |s|
        s.publicize
        s.save!
        s.collection_inclusions.create!(resource_noid: collection.noid)
      end
      expect(search("/compilations/#{set.noid}/search")['results'].pluck('klass').uniq).to eq(['Work'])

      get "/resources/#{community.noid}/descendant_works", headers: signed_auth_headers(nil)
      expect(response.parsed_body['works'].pluck('klass').uniq).to eq(['Work'])
    end

    it 'ORs the values in one field and ANDs the fields' do
      either = search("/collections/#{collection.noid}/search", f: { genre_ssim: %w[Photographs Maps] })
      expect(either['results'].pluck('noid'))
        .to contain_exactly(albatross_photo.noid, harbor_photo.noid, albatross_map.noid)

      both = search("/collections/#{collection.noid}/search",
                    f: { genre_ssim: %w[Photographs], pub_date_ssim: %w[1998] })
      expect(both['results'].pluck('noid')).to eq([harbor_photo.noid])
    end

    it 'counts facets over the whole result, bounded by facet_limit' do
      body = search("/communities/#{community.noid}/search", facet: %w[genre_ssim pub_date_ssim], per_page: 1)
      expect(body['results'].length).to eq(1)
      expect(body.dig('facets', 'genre_ssim'))
        .to eq([{ 'value' => 'Photographs', 'count' => 3 }, { 'value' => 'Maps', 'count' => 1 }])

      limited = search("/communities/#{community.noid}/search", facet: %w[genre_ssim], facet_limit: 1)
      expect(limited.dig('facets', 'genre_ssim')).to eq([{ 'value' => 'Photographs', 'count' => 3 }])
    end

    it 'sorts by title and by date' do
      by_title = search("/communities/#{community.noid}/search", sort: 'title')
      expect(by_title['results'].pluck('title').first(2))
        .to match([start_with('Albatross ashore'), start_with('Albatross at sea')])

      by_date = search("/communities/#{community.noid}/search", sort: 'date')
      works = by_date['results'].select { |row| row['klass'] == 'Work' }
      expect(works.pluck('noid').last).to eq(harbor_photo.noid)
    end

    it 'hides non-public, embargoed, in-progress and incomplete Works from a guest' do
      hidden = [
        work_in(collection, title: 'Albatross private').tap do |w|
          w.read_groups = []
          Atlas.persister.save(resource: w)
        end,
        work_in(collection, title: 'Albatross embargoed', embargo_release_date: 1.year.from_now),
        work_in(collection, title: 'Albatross unfinished', in_progress: true),
        work_in(collection, title: 'Albatross incomplete', incomplete: true)
      ]
      body = search("/collections/#{collection.noid}/search", q: 'albatross', facet: %w[genre_ssim])
      expect(body['results'].pluck('noid')).to contain_exactly(albatross_photo.noid, albatross_map.noid)
      expect(body['results'].pluck('noid')).not_to include(*hidden.map(&:noid))
      expect(body.dig('facets', 'genre_ssim').sum { |row| row['count'] }).to eq(2)
    end

    it 'hides embargoed, in-progress and incomplete Works from an admin too' do
      hidden = [
        work_in(collection, title: 'Albatross embargoed', embargo_release_date: 1.year.from_now),
        work_in(collection, title: 'Albatross unfinished', in_progress: true),
        work_in(collection, title: 'Albatross incomplete', incomplete: true)
      ]
      get "/collections/#{collection.noid}/search",
          params: { q: 'albatross' }, headers: signed_auth_headers(ensure_default_admin!.nuid)
      expect(noids(response)).to contain_exactly(albatross_photo.noid, albatross_map.noid)
      expect(noids(response)).not_to include(*hidden.map(&:noid))
    end

    it 'adds linked Works on the container routes only when include_linked is set' do
      linked = work_in(other, title: 'Albatross linked').tap do |w|
        w.a_linked_member_of = [collection.id]
        Atlas.persister.save(resource: w)
      end
      expect(search("/collections/#{collection.noid}/search", q: 'linked')['results']).to be_empty
      expect(search("/collections/#{collection.noid}/search", q: 'linked', include_linked: true)['results']
               .pluck('noid')).to eq([linked.noid])
    end

    it 'answers 404 for a Community id on the Collection route' do
      get "/collections/#{community.noid}/search", headers: signed_auth_headers(nil)
      expect(response).to have_http_status(:not_found)
    end

    it 'answers 400 for f that is not keyed by field' do
      get "/collections/#{collection.noid}/search", params: { f: 'genre_ssim' }, headers: signed_auth_headers(nil)
      expect(response).to have_http_status(:bad_request)
    end

    it 'answers 403 to a guest on a private Set' do
      set = Compilation.create!(title: 'Private', depositor: '000000002')
      get "/compilations/#{set.noid}/search", headers: signed_auth_headers(nil)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
