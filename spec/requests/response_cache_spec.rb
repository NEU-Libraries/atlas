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
    it "caches an operator's 410 and replays its status" do
      admin = ensure_default_admin!
      work = public_work
      work.tombstone(by: reader.nuid)
      Atlas.persister.save(resource: work)

      2.times { get "/works/#{work.noid}", headers: signed_auth_headers(admin.nuid) }
      expect(response).to have_http_status(:gone)
      expect(response.headers['X-Atlas-Cache']).to eq('hit')
    end

    # The cached 410 is the full record. Below the operator tiers the stub is
    # answered before the cache is read, so a warm entry never reaches them.
    it 'answers a guest the tombstone stub even when the full 410 is cached' do
      admin = ensure_default_admin!
      work = public_work
      work.tombstone(by: reader.nuid)
      Atlas.persister.save(resource: work)

      2.times { get "/works/#{work.noid}", headers: signed_auth_headers(admin.nuid) }
      expect(response.parsed_body['work']).to include('description')

      get "/works/#{work.noid}"
      expect(response).to have_http_status(:gone)
      expect(response.headers['X-Atlas-Cache']).to be_nil
      expect(response.parsed_body['work'].keys)
        .to match_array(%w[id title permanent_url tombstoned tombstoned_at tombstone_reason])
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
      expect(cached_scopes_for(public_work.noid)).to include('works.show/guest', 'works.mods.json/any')

      Atlas.persister.save(resource: Work.find(public_work.noid))
      expect(cached_scopes_for(public_work.noid)).to be_empty
    end

    # mets_xml= saves the METS Blob, which evicts, and only then writes the
    # metadata_mets row the body is rendered from.
    it 'drops the cached METS when the metadata_mets row is written' do
      FileSetCreator.call(work_id: public_work.noid, classification: Classification.image, position: 1)
      work = WorkMETSRebuilder.call(work: public_work)
      get "/works/#{work.noid}/mets"
      expect(response).to have_http_status(:ok)
      expect(cached_scopes_for(work.noid)).to include('works.mets/any')

      work.mets_json = work.mets_xml

      expect(cached_scopes_for(work.noid)).not_to include('works.mets/any')
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

  # A file write saves the FileSet and the Blob, never the Work, yet both file
  # listings are cached under the Work's NOID.
  describe "a file write reaches its Work's file listings" do
    let(:example_png) { Rails.root.join('spec/fixtures/files/example.png').to_s }
    let(:file_scopes) { %w[works.assets/authenticated works.file_sets/authenticated] }
    let!(:blob) do
      BlobCreator.call(path: example_png, work_id: public_work.noid, original_filename: 'example.png')
    end

    def warm_file_listings(work)
      get "/works/#{work.noid}/assets", headers: signed_auth_headers(reader.nuid)
      get "/works/#{work.noid}/file_sets", headers: signed_auth_headers(reader.nuid)
      expect(cached_scopes_for(work.noid)).to include(*file_scopes)
    end

    def listed_filenames(work)
      get "/works/#{work.noid}/assets", headers: signed_auth_headers(reader.nuid)
      expect(response.headers['X-Atlas-Cache']).to eq('miss')
      response.parsed_body.pluck('original_filename')
    end

    it 'lists an added file on the next read' do
      warm_file_listings(public_work)

      BlobCreator.call(path: example_png, work_id: public_work.noid, original_filename: 'second.png')

      expect(cached_scopes_for(public_work.noid)).not_to include(*file_scopes)
      expect(listed_filenames(public_work)).to include('example.png', 'second.png')
    end

    it 'drops the listings when a file is replaced' do
      warm_file_listings(public_work)

      BlobRevisionAppender.call(blob: Blob.find(blob.noid), source_path: example_png, name: 'renamed.png')

      expect(cached_scopes_for(public_work.noid)).not_to include(*file_scopes)
      expect(listed_filenames(public_work)).to include('renamed.png')
    end

    it 'drops the listings when a Blob alone is saved' do
      warm_file_listings(public_work)

      Atlas.persister.save(resource: Blob.find(blob.noid))

      expect(cached_scopes_for(public_work.noid)).not_to include(*file_scopes)
    end

    it 'drops the listings when a FileSet is tombstoned and when it is restored' do
      admin = ensure_default_admin!
      file_set = Blob.find(blob.noid).parent

      warm_file_listings(public_work)
      post "/resources/#{file_set.noid}/tombstone", headers: signed_auth_headers(admin.nuid)
      expect(response).to have_http_status(:ok)
      expect(cached_scopes_for(public_work.noid)).not_to include(*file_scopes)
      expect(listed_filenames(public_work)).not_to include('example.png')

      warm_file_listings(public_work)
      post "/resources/#{file_set.noid}/restore", headers: signed_auth_headers(admin.nuid)
      expect(response).to have_http_status(:ok)
      expect(cached_scopes_for(public_work.noid)).not_to include(*file_scopes)
      expect(listed_filenames(public_work)).to include('example.png')
    end

    it "leaves the Work's entries alone when an unrelated resource is saved" do
      other = restricted_work
      warm_file_listings(public_work)

      Atlas.persister.save(resource: Work.find(other.noid))
      BlobCreator.call(path: example_png, work_id: other.noid, original_filename: 'elsewhere.png')

      expect(cached_scopes_for(public_work.noid)).to include(*file_scopes)
    end

    it 'never fails the write when the owner lookup raises' do
      warm_file_listings(public_work)
      allow(Atlas.query.custom_queries).to receive(:find_many_parents).and_raise(StandardError, 'boom')

      expect { Atlas.persister.save(resource: Blob.find(blob.noid)) }.not_to raise_error
    end
  end

  # A Person's body lists its affiliated Communities, and purging one does not
  # save the Person.
  describe 'purging an affiliated Community' do
    it "drops the Person's cached body" do
      admin = ensure_default_admin!
      affiliated = public_community!
      person = PersonCreator.call(nuid: '000000077', display_name: 'Roe, Rita')
      person.affiliated_community_ids = [affiliated.id]
      person = Atlas.persister.save(resource: person)

      get "/people/#{person.noid}", headers: signed_auth_headers(admin.nuid)
      expect(response.parsed_body.to_s).to include(affiliated.noid)
      expect(cached_scopes_for(person.noid)).to include('people.show/any')

      ResourcePurger.call(resource: Community.find(affiliated.noid))

      expect(cached_scopes_for(person.noid)).to be_empty
      get "/people/#{person.noid}", headers: signed_auth_headers(admin.nuid)
      expect(response.parsed_body.to_s).not_to include(affiliated.noid)
    end
  end

  # A container's title is embedded in every descendant Work's `ancestors`, and
  # nothing re-saves those Works — so a rename or a move has to reach them.
  describe 'the ancestor cascade' do
    it 'drops a descendant Work when its container is renamed' do
      child = public_work
      get "/works/#{child.noid}"
      expect(cached_scopes_for(child.noid)).to include('works.show/guest')

      set_mods_primary_title!(Collection.find(collection.noid), 'A Renamed Collection')

      expect(cached_scopes_for(child.noid)).to be_empty
    end

    it 'drops a descendant Work when its container moves' do
      child = public_work
      destination = public_community!
      get "/works/#{child.noid}"
      expect(cached_scopes_for(child.noid)).to include('works.show/guest')

      Reparenter.call(node: Collection.find(collection.noid), destination: destination)

      expect(cached_scopes_for(child.noid)).to be_empty
    end

    it 'drops a descendant Collection when its Community is renamed' do
      sub = CollectionCreator.call(parent_id: collection.noid)
      get "/collections/#{sub.noid}"
      expect(cached_scopes_for(sub.noid)).to include('collections.show/guest')

      set_mods_primary_title!(Community.find(community.noid), 'A Renamed Community')

      expect(cached_scopes_for(sub.noid)).to be_empty
      get "/collections/#{sub.noid}"
      expect(response.parsed_body.dig('collection', 'ancestors').pluck('title')).to include('A Renamed Community')
    end

    it 'drops a descendant Collection when its parent Collection moves' do
      sub = CollectionCreator.call(parent_id: collection.noid)
      destination = public_community!
      get "/collections/#{sub.noid}"
      expect(cached_scopes_for(sub.noid)).to include('collections.show/guest')

      Reparenter.call(node: Collection.find(collection.noid), destination: destination)

      expect(cached_scopes_for(sub.noid)).to be_empty
      get "/collections/#{sub.noid}"
      expect(response.parsed_body.dig('collection', 'ancestors').pluck('noid')).to include(destination.noid)
    end
  end
end
