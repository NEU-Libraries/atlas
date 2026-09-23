# frozen_string_literal: true

require 'rails_helper'

# A typed route answers an id of another type exactly as it answers an unknown
# id: 404. The admin default principal passes every class-level gate, so each
# 404 here comes from the typed find, not from authorization.
RSpec.describe 'Typed routes refuse an id of another type', type: :request do
  let(:fixture) { Rails.root.join('spec/fixtures/files/example.bin') }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:blob) do
    BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s)
  end
  let(:file_set) { blob.parent }
  let(:delegate) do
    DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name,
                         uri: 'https://iiif.example/iiif/2/abc/full/!200,200/0/default.jpg')
  end
  let(:person) { PersonCreator.call(nuid: '001234567', display_name: 'Doe, Jane') }

  let(:ids) do
    { Community => community.noid, Collection => collection.noid, Work => work.noid,
      FileSet => file_set.noid, Blob => blob.noid, Delegate => delegate.noid,
      Person => person.noid }
  end

  after { Atlas.persister.wipe! }

  {
    Work       => %w[/works/%s /works/%s/mods /works/%s/mets /works/%s/assets /works/%s/file_sets],
    Collection => %w[/collections/%s /collections/%s/mods /collections/%s/children],
    Community  => %w[/communities/%s /communities/%s/mods /communities/%s/children],
    FileSet    => %w[/file_sets/%s /file_sets/%s/mets],
    Blob       => %w[/files/%s /files/%s/content /files/%s/ancestry /files/%s/versions
                     /files/%s/versions/v1/content],
    Delegate   => %w[/delegates/%s],
    Person     => %w[/people/%s]
  }.each do |klass, paths|
    it "GET on the #{klass} routes 404s for every other type's id" do
      aggregate_failures do
        ids.except(klass).each do |other, id|
          paths.each do |path|
            get format(path, id)
            expect(response).to have_http_status(:not_found), "#{format(path, id)} (a #{other})"
          end
        end
      end
    end
  end

  describe 'the destructive actions' do
    it 'DELETE /file_sets/:id does not purge a Collection' do
      delete "/file_sets/#{collection.noid}"
      expect(response).to have_http_status(:not_found)
      expect(Collection.find(collection.noid)).to be_present
      expect(Work.find(work.noid)).to be_present
    end

    it 'DELETE /file_sets/:id does not purge a Work' do
      delete "/file_sets/#{work.noid}"
      expect(response).to have_http_status(:not_found)
      expect(Work.find(work.noid)).to be_present
    end

    it 'DELETE /files/:id does not purge a Work' do
      delete "/files/#{work.noid}"
      expect(response).to have_http_status(:not_found)
      expect(Work.find(work.noid)).to be_present
    end

    it 'PATCH /files/:id does not append a revision to a Work' do
      patch "/files/#{work.noid}", params: { binary: Rack::Test::UploadedFile.new(fixture) }
      expect(response).to have_http_status(:not_found)
      expect(AuditEvent.where(action: 'replace_file')).to be_empty
    end

    it 'POST /files/:id/rollback does not reach a Work' do
      post "/files/#{work.noid}/rollback", params: { version_id: 'v1' }
      expect(response).to have_http_status(:not_found)
    end

    it 'PATCH /file_sets/:id does not attach a Blob under a Work' do
      target = work.noid
      blobs_before = Atlas.query.count_all_of_model(model: Blob)
      patch "/file_sets/#{target}", params: { binary: Rack::Test::UploadedFile.new(fixture) }
      expect(response).to have_http_status(:not_found)
      expect(Atlas.query.count_all_of_model(model: Blob)).to eq(blobs_before)
    end

    it 'PATCH /file_sets/:id/iiif_service does not reach a Work' do
      patch "/file_sets/#{work.noid}/iiif_service", params: { uri: 'https://iiif.example/iiif/2/abc' }
      expect(response).to have_http_status(:not_found)
    end
  end
end
