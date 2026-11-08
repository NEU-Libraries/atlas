# frozen_string_literal: true

require 'rails_helper'

# What an embargo withholds beyond the file bytes: the gated image URLs, and the
# Work's extracted full text from the search index. The read matrix holds the
# URLs on every route with the cache off; this covers the cache, and the index
# before, during and after an embargo. See docs/authorization.md.
#
# default_auth: false — the global admin default bypasses the embargo.
RSpec.describe 'An embargo withholds the gated URLs and the full text', type: :request, default_auth: false do
  include ActiveSupport::Testing::TimeHelpers

  let!(:guest) do
    User.find_by(role: :guest) ||
      User.create!(email: 'guest-embargo@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000001', name: 'User, Guest', role: :guest)
  end
  let!(:admin) { ensure_default_admin! }
  let!(:standard) do
    User.create!(email: 'standard-embargo@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000081', name: 'Doe, Standard', role: :standard, groups: [])
  end
  let!(:staff) do
    User.create!(email: 'staff-embargo@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000082', name: 'Poe, Staff', role: :standard, groups: [Permissions::STAFF_EDIT_GROUP])
  end
  let(:phrase) { 'zqembargoedphrase' }
  let(:gated_uri) { 'https://iiif.example/gated-zqembargoedimage/full/max/0/default.jpg' }
  let!(:work) do
    work = WorkCreator.call(parent_id: CollectionCreator.call(parent_id: public_community!.noid).noid)
    work.publicize
    work.full_text = "a report that mentions #{phrase} once"
    # Search lists a finished deposit only.
    work.in_progress = false
    work = Atlas.persister.save(resource: work)
    DelegateCreator.call(resource_id: work.id, use: Role.large_image.name, uri: gated_uri)
    Work.find(work.noid)
  end

  after { Atlas.persister.wipe! }

  def embargo!(until_time)
    resource = Work.find(work.noid)
    resource.embargo_release_date = until_time
    Atlas.persister.save(resource: resource)
  end

  def found_by?(user)
    get '/resources/search', params: { q: phrase }, headers: signed_auth_headers(user&.nuid)
    response.parsed_body['results'].any? { |hit| hit['noid'] == work.noid }
  end

  def assets_uri_for(user)
    get "/works/#{work.noid}/assets", headers: signed_auth_headers(user&.nuid)
    response.parsed_body.find { |asset| asset['use'] == Role.large_image.name }&.fetch('uri')
  end

  describe 'the full text' do
    it 'is searchable before the embargo' do
      expect(found_by?(nil)).to be(true)
    end

    it 'leaves the index while the embargo holds, for every caller' do
      embargo!(1.year.from_now)
      expect([found_by?(nil), found_by?(staff), found_by?(admin)]).to eq([false, false, false])
    end

    it 'returns when the release sweep finds the embargo lapsed' do
      embargo!(3.days.from_now)
      travel_to(5.days.from_now) do
        expect(found_by?(nil)).to be(false)
        EmbargoReleaseRecorder.call(actor: admin, event_source: 'job')
        expect(found_by?(nil)).to be(true)
      end
    end
  end

  describe 'the gated image URL', :response_cache do
    it 'is withheld below the bypass even after a bypass caller filled the cache' do
      embargo!(1.year.from_now)
      expect(assets_uri_for(staff)).to eq(gated_uri)
      expect([assets_uri_for(standard), assets_uri_for(nil)]).to eq([nil, nil])
      expect(assets_uri_for(admin)).to eq(gated_uri)
    end

    it 'returns to everyone once the embargo lapses, without a stale cached body' do
      embargo!(3.days.from_now)
      expect(assets_uri_for(nil)).to be_nil
      travel_to(5.days.from_now) { expect(assets_uri_for(nil)).to eq(gated_uri) }
    end
  end
end
