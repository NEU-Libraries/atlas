# frozen_string_literal: true

require 'rails_helper'

# The byte routes withhold a Work's file bytes under an embargo and under a tier
# reservation. The access matrix covers the tiers it shares with the other
# states; this covers the callers it has no tier for: staff, a member of the
# reserved group, and the descriptive-metadata Blob. See docs/authorization.md.
#
# default_auth: false — the global admin default bypasses both gates.
RSpec.describe 'Withheld file bytes', type: :request, default_auth: false do
  let(:reserved) { 'northeastern:drs:withheld:reserved' }
  let!(:guest) do
    User.find_by(role: :guest) ||
      User.create!(email: 'guest-withheld@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000001', name: 'User, Guest', role: :guest)
  end
  let!(:admin) { ensure_default_admin! }
  let!(:editor) do
    User.create!(email: 'editor-withheld@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000071', name: 'Roe, Editor', role: :standard, groups: [])
  end
  let!(:staff) do
    User.create!(email: 'staff-withheld@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000072', name: 'Poe, Staff', role: :standard,
                 groups: [Permissions::STAFF_EDIT_GROUP])
  end
  let!(:member) do
    User.create!(email: 'member-withheld@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000073', name: 'Moe, Member', role: :standard, groups: [reserved])
  end
  let!(:system_user) do
    User.create!(email: 'system-withheld@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000000', name: 'System', role: :system)
  end

  let(:fixture)    { Rails.root.join('spec/fixtures/files/example.bin') }
  let(:collection) { CollectionCreator.call(parent_id: public_community!.noid) }
  let(:work) do
    work = WorkCreator.call(parent_id: collection.noid)
    work.publicize
    work.edit_users = [editor.nuid]
    Atlas.persister.save(resource: work)
  end
  let(:blob) { BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s) }

  after { Atlas.persister.wipe! }

  def withhold!(**attributes)
    resource = Work.find(work.noid)
    attributes.each { |key, value| resource.public_send(:"#{key}=", value) }
    Atlas.persister.save(resource: resource)
  end

  def status_for(user, path = "/files/#{blob.noid}/content")
    get path, headers: signed_auth_headers(user&.nuid)
    response.status
  end

  def system_status
    allow(Rails.application.credentials).to receive(:system_token).and_return('test-system-token')
    get "/files/#{blob.noid}/content",
        headers: { 'Authorization' => 'Bearer test-system-token', 'User' => "NUID #{system_user.nuid}" }
    response.status
  end

  context 'when the Work is under embargo' do
    before do
      blob
      withhold!(embargo_release_date: 1.year.from_now)
    end

    it 'serves staff and the admin, as Cerberus does' do
      expect([status_for(staff), status_for(admin)]).to eq([200, 200])
    end

    it 'refuses the editor and the guest, naming the embargo' do
      expect([status_for(editor), status_for(nil)]).to eq([403, 403])
      expect(response.parsed_body['error']).to include('embargo')
    end

    it 'refuses :system, which never fetches bytes for a person' do
      expect(system_status).to eq(403)
    end

    it 'refuses a pinned version as it refuses the head' do
      expect(status_for(editor, "/files/#{blob.noid}/versions/v1/content")).to eq(403)
    end

    it 'serves the descriptive metadata, which stays public under embargo' do
      mods = Work.find(work.noid).mods_blob
      expect(status_for(nil, "/files/#{mods.noid}/content")).to eq(200)
    end

    it 'serves again once the release date has passed' do
      withhold!(embargo_release_date: 1.year.ago)
      expect(status_for(nil)).to eq(200)
    end
  end

  context 'when the file tier is reserved to a group' do
    before do
      blob
      withhold!(derivative_permissions: { generic: [reserved] }.to_json)
    end

    it 'serves a member of the group' do
      expect(status_for(member)).to eq(200)
    end

    it 'refuses the editor, whose edit grant does not join the audience' do
      expect(status_for(editor)).to eq(403)
      expect(response.parsed_body['error']).to include('reserved')
    end

    it 'refuses staff, whose bypass is for embargoes only' do
      expect(status_for(staff)).to eq(403)
    end

    it 'serves the editor of a private Work, whose tier is no narrower than the Work' do
      withhold!(read_groups: [], derivative_permissions: nil)
      expect(status_for(editor)).to eq(200)
    end

    it 'serves a Range request to nobody it would refuse whole' do
      get "/files/#{blob.noid}/content", headers: signed_auth_headers(nil).merge('Range' => 'bytes=0-9')
      expect(response).to have_http_status(:forbidden)
    end
  end
end
