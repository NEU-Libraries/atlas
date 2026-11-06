# frozen_string_literal: true

require 'rails_helper'

# A tombstone withholds the files beneath it. Neither a FileSet's nor a Work's
# tombstone sets the flag on the Blobs below it, so each route here has to read
# the ancestors. Operators keep access, to review a removed file before restoring.
#
# default_auth: false — the global admin default is an operator and would be
# served everything.
RSpec.describe 'Tombstone withholds file access', type: :request, default_auth: false do
  let!(:guest) do
    User.create!(email: 'guest-tombstone@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000001', name: 'User, Guest', role: :guest)
  end
  let!(:editor) do
    User.create!(email: 'editor-tombstone@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000061', name: 'Roe, Editor', role: :standard, groups: [])
  end
  let!(:delegate) do
    User.create!(email: 'delegate-tombstone@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000062', name: 'Williams, Delegate', role: :privileged,
                 groups: [Permissions::ADMIN_GROUP])
  end
  let!(:admin) { ensure_default_admin! }

  let(:fixture)    { Rails.root.join('spec/fixtures/files/example.bin') }
  let(:collection) { CollectionCreator.call(parent_id: public_community!.noid) }
  let(:work) do
    work = WorkCreator.call(parent_id: collection.noid)
    work.publicize
    work.edit_users = [editor.nuid]
    Atlas.persister.save(resource: work)
  end
  let(:blob)     { BlobCreator.call(work_id: work.noid, original_filename: 'es.vtt', path: fixture.to_s) }
  let(:file_set) { blob.parent }

  after { Atlas.persister.wipe! }

  def tombstone!(resource)
    resource = Resource.find(resource.noid)
    resource.tombstone(by: admin.nuid)
    Atlas.persister.save(resource: resource)
  end

  def restore!(resource)
    resource = Resource.find(resource.noid)
    resource.restore
    Atlas.persister.save(resource: resource)
  end

  def headers_for(user)
    signed_auth_headers(user.guest? ? nil : user.nuid)
  end

  def version_id
    get "/files/#{blob.noid}/versions", headers: headers_for(admin)
    response.parsed_body['versions'].first['version_id']
  end

  def expect_withheld(source)
    expect(response).to have_http_status(:gone)
    expect(response.parsed_body).to include('error'                    => 'tombstoned',
                                            'tombstoned_resource_id'   => source.noid,
                                            'tombstoned_resource_type' => source.class.name)
    expect(response.body).not_to include(File.binread(fixture))
  end

  shared_examples 'withholds the bytes below the operator tiers' do
    it 'refuses the content, a byte range and a pinned revision to a guest and to an editor of the Work' do
      pinned = version_id
      [guest, editor].each do |user|
        get "/files/#{blob.noid}/content", headers: headers_for(user)
        expect_withheld(source)

        get "/files/#{blob.noid}/content", headers: headers_for(user).merge('Range' => 'bytes=0-9')
        expect_withheld(source)

        get "/files/#{blob.noid}/versions/#{pinned}/content", headers: headers_for(user)
        expect_withheld(source)
      end
    end

    it 'serves the content to an admin and a delegated admin' do
      [admin, delegate].each do |user|
        get "/files/#{blob.noid}/content", headers: headers_for(user)
        expect(response).to have_http_status(:ok)
        expect(response.body.b).to eq(File.binread(fixture))
      end
    end

    it 'withholds the record from a guest, naming the tombstoned resource' do
      get "/files/#{blob.noid}", headers: headers_for(guest)
      expect_withheld(source)
      expect(response.parsed_body).not_to have_key('blob')
    end

    it 'answers an operator the record as 410, naming the tombstoned resource' do
      get "/files/#{blob.noid}", headers: headers_for(delegate)
      expect(response).to have_http_status(:gone)
      expect(response.parsed_body['blob']).to include('tombstoned'               => false,
                                                      'tombstoned_in_effect'     => true,
                                                      'tombstoned_resource_id'   => source.noid,
                                                      'tombstoned_resource_type' => source.class.name)
    end

    it 'serves the content again once restored' do
      restore!(source)
      get "/files/#{blob.noid}/content", headers: headers_for(guest)
      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq(File.binread(fixture))
    end
  end

  context 'when the FileSet is tombstoned' do
    let(:source) { file_set }

    before { tombstone!(file_set) }

    include_examples 'withholds the bytes below the operator tiers'

    it 'reports the FileSet tombstoned and the Work live on the ancestry read' do
      get "/files/#{blob.noid}/ancestry", headers: headers_for(guest)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('file_set' => file_set.noid, 'work' => work.noid,
                                         'file_set_tombstoned' => true, 'work_tombstoned' => false)
    end
  end

  context 'when the Work is tombstoned' do
    let(:source) { work }

    before do
      blob
      tombstone!(work)
    end

    include_examples 'withholds the bytes below the operator tiers'

    it 'refuses the file lists to a guest and to an editor of the Work' do
      [guest, editor].each do |user|
        %w[assets file_sets file_revisions].each do |route|
          get "/works/#{work.noid}/#{route}", headers: headers_for(user)
          expect_withheld(work)
        end
      end
    end

    it 'lists the files for an admin and a delegated admin' do
      [admin, delegate].each do |user|
        get "/works/#{work.noid}/assets", headers: headers_for(user)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.pluck('noid')).to include(blob.noid)
      end
    end

    # The operator's 200 is cached under the same audience a staff caller
    # shares, so the gate must run before the cache is read.
    it 'refuses a guest even after an operator has warmed the response cache' do
      get "/works/#{work.noid}/assets", headers: headers_for(delegate)
      expect(response).to have_http_status(:ok)

      get "/works/#{work.noid}/assets", headers: headers_for(editor)
      expect_withheld(work)
    end

    it 'reports the Work tombstoned on the ancestry read' do
      get "/files/#{blob.noid}/ancestry", headers: headers_for(guest)
      expect(response.parsed_body).to include('file_set_tombstoned' => false, 'work_tombstoned' => true)
    end

    it 'answers the FileSet read 410 as well' do
      get "/file_sets/#{file_set.noid}", headers: headers_for(guest)
      expect(response).to have_http_status(:gone)
    end
  end

  # A caller who may not read the Work learns nothing about its tombstone.
  it 'answers 403, not 410, to a caller without read access' do
    work.privatize
    Atlas.persister.save(resource: work)
    tombstone!(file_set)

    get "/files/#{blob.noid}/content", headers: headers_for(guest)
    expect(response).to have_http_status(:forbidden)
  end
end
