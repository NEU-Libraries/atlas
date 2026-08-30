# frozen_string_literal: true

require 'rails_helper'

# The response cache over the wire: what it serves, what it refuses to serve,
# and what drops it.
#
# The first block is the one that matters. Caching a rendered body is only safe
# because authorization runs against the LIVE resource before the cache is ever
# consulted — the PoC this work came from cached in Rack middleware, outside
# Rails, and so answered hits without reaching Ability at all.
RSpec.describe 'Response cache', :response_cache, type: :request, default_auth: false do
  let!(:guest) do
    User.create!(email: 'guest@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000001', name: 'User, Guest', role: :guest)
  end
  let!(:reader) do
    User.create!(email: 'reader@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000002', name: 'Doe, Jane', role: :standard,
                 groups: ['northeastern:drs:test-readers'])
  end

  let(:community)  { public_community! }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  let(:public_work) do
    work = WorkCreator.call(parent_id: collection.noid)
    work.publicize
    Atlas.persister.save(resource: work)
  end

  let(:restricted_work) do
    work = WorkCreator.call(parent_id: collection.noid)
    work.privatize
    work.add_read_group('northeastern:drs:test-readers')
    Atlas.persister.save(resource: work)
  end

  after { Atlas.persister.wipe! }

  describe 'authorization still runs on a hit' do
    it 'refuses a guest the body it just cached for an authorized reader' do
      get "/works/#{restricted_work.noid}", headers: signed_auth_headers(reader.nuid)
      expect(response).to have_http_status(:ok)
      expect(response.headers['X-Atlas-Cache']).to eq('miss')

      get "/works/#{restricted_work.noid}", headers: signed_auth_headers(reader.nuid)
      expect(response.headers['X-Atlas-Cache']).to eq('hit')

      # Same key, no rights: the gate runs before the cache is consulted.
      get "/works/#{restricted_work.noid}"
      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include(restricted_work.noid)
    end
  end

  describe 'hits and misses' do
    it 'serves the second read from the cache, byte for byte' do
      get "/works/#{public_work.noid}"
      first = response.body
      expect(response.headers['X-Atlas-Cache']).to eq('miss')
      first_type = response.headers['Content-Type']

      get "/works/#{public_work.noid}"
      expect(response.headers['X-Atlas-Cache']).to eq('hit')
      expect(response.body).to eq(first)
      expect(response.headers['Content-Type']).to eq(first_type)
    end

    it 'does not cache a 404' do
      get '/works/nosuchnoid'
      expect(response).to have_http_status(:not_found)
      expect(cached_scopes_for('nosuchnoid')).to be_empty
    end

    # A tombstoned Work answers `gone` with a stable body until something
    # writes to it, and that write evicts — so 410 is as cacheable as 200.
    it 'caches a 410 and replays its status' do
      work = public_work
      work.tombstone(by: reader.nuid)
      Atlas.persister.save(resource: work)

      get "/works/#{work.noid}"
      expect(response).to have_http_status(:gone)
      get "/works/#{work.noid}"
      expect(response).to have_http_status(:gone)
      expect(response.headers['X-Atlas-Cache']).to eq('hit')
    end

    it 'keeps each MODS format in its own entry' do
      get "/works/#{public_work.noid}/mods.json"
      get "/works/#{public_work.noid}/mods.html"
      expect(response.headers['X-Atlas-Cache']).to eq('miss')
      expect(response.media_type).to eq('text/html')

      get "/works/#{public_work.noid}/mods.json"
      expect(response.headers['X-Atlas-Cache']).to eq('hit')
      expect(response.media_type).to eq('application/json')
    end
  end

  # works/_asset.json.jbuilder withholds the `permission` group list from
  # guests. That is the only caller-varying field in any cached view, so the
  # two audiences must never share an entry.
  describe 'the guest / authenticated split on assets' do
    let!(:blob) do
      BlobCreator.call(path: Rails.root.join('spec/fixtures/files/example.png').to_s,
                       work_id: public_work.noid, original_filename: 'example.png')
    end

    it 'never serves a guest the authenticated body' do
      get "/works/#{public_work.noid}/assets", headers: signed_auth_headers(reader.nuid)
      authenticated_body = response.body

      get "/works/#{public_work.noid}/assets"
      expect(response.headers['X-Atlas-Cache']).to eq('miss')
      expect(response.body).not_to eq(authenticated_body)
      expect(response.parsed_body.pluck('permission')).to all(be_nil)

      get "/works/#{public_work.noid}/assets", headers: signed_auth_headers(reader.nuid)
      expect(response.headers['X-Atlas-Cache']).to eq('hit')
      expect(response.body).to eq(authenticated_body)
    end
  end

  describe 'eviction' do
    it 'drops every cached representation when the resource is written' do
      get "/works/#{public_work.noid}"
      get "/works/#{public_work.noid}/mods.json"
      expect(cached_scopes_for(public_work.noid)).to include('works.show/any', 'works.mods.json/any')

      Atlas.persister.save(resource: Work.find(public_work.noid))
      expect(cached_scopes_for(public_work.noid)).to be_empty
    end

    it 'reflects a metadata write on the next read' do
      get "/works/#{public_work.noid}"
      expect(response.parsed_body.dig('work', 'title')).to be_blank

      set_mods_primary_title!(Work.find(public_work.noid), 'A Retitled Work')

      get "/works/#{public_work.noid}"
      expect(response.headers['X-Atlas-Cache']).to eq('miss')
      expect(response.parsed_body.dig('work', 'title')).to eq('A Retitled Work')
    end
  end

  # A container's title is embedded in every descendant Work's `ancestors`, and
  # nothing re-saves those Works — so a rename or a move has to reach them.
  describe 'the ancestor cascade' do
    it 'drops a descendant Work when its container is renamed' do
      child = public_work
      get "/works/#{child.noid}"
      expect(cached_scopes_for(child.noid)).to include('works.show/any')

      set_mods_primary_title!(Collection.find(collection.noid), 'A Renamed Collection')

      expect(cached_scopes_for(child.noid)).to be_empty
    end

    it 'drops a descendant Work when its container moves' do
      child = public_work
      destination = public_community!
      get "/works/#{child.noid}"
      expect(cached_scopes_for(child.noid)).to include('works.show/any')

      Reparenter.call(node: Collection.find(collection.noid), destination: destination)

      expect(cached_scopes_for(child.noid)).to be_empty
    end
  end
end
