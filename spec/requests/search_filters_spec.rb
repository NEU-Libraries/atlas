# frozen_string_literal: true

require 'rails_helper'

# Who finds what through GET /resources/search. default_auth: false because the
# admin default skips the read gate and would prove nothing about it.
RSpec.describe 'Search filters and the read gate', type: :request, default_auth: false do
  let(:reader_group) { 'northeastern:drs:test-readers' }

  let!(:guest) do
    User.find_by(role: :guest) ||
      User.create!(email: 'guest@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000001', role: :guest)
  end
  let!(:admin) { ensure_default_admin! }
  let!(:reader) { make_user('000000002', :standard, [reader_group]) }
  let!(:staff) { make_user('000000003', :privileged, [Permissions::STAFF_EDIT_GROUP]) }
  let!(:depositor) { make_user('000000005', :standard, []) }

  let(:community)  { public_community! }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  after { Atlas.persister.wipe! }

  def make_user(nuid, role, groups)
    User.create!(email: "#{nuid}@example.invalid", password: SecureRandom.hex(16),
                 nuid: nuid, role: role, groups: groups)
  end

  # Every Work here shares the word "zeppelin", so one query reaches them all
  # and each example asserts only on who sees which. WorkCreator makes Works
  # in progress; a finished one is the normal case.
  def work(title, **attrs)
    w = WorkCreator.call(parent_id: collection.noid)
    Work.find(w.noid).mods_xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <mods:mods xmlns:mods="http://www.loc.gov/mods/v3">
        <mods:titleInfo usage="primary"><mods:title>#{title} zeppelin</mods:title></mods:titleInfo>
      </mods:mods>
    XML
    w = Work.find(w.noid)
    defaults = { read_groups: ['public'], edit_groups: [], depositor: nil, in_progress: false, tombstoned: false }
    defaults.merge(attrs).each { |name, value| w.public_send(:"#{name}=", value) }
    Atlas.persister.save(resource: w)
  end

  def found(nuid, query = 'zeppelin', **params)
    get '/resources/search', params: { q: query, **params }, headers: signed_auth_headers(nuid)
    expect(response).to have_http_status(:ok)
    response.parsed_body['results'].pluck('noid')
  end

  describe 'the read gate' do
    let!(:public_work)   { work('Public') }
    let!(:group_work)    { work('Group', read_groups: [reader_group]) }
    let!(:staff_work)    { work('Staff', read_groups: [], edit_groups: [Permissions::STAFF_EDIT_GROUP]) }
    let!(:deposited)     { work('Deposited', read_groups: [], depositor: depositor.nuid) }

    it 'shows a guest public Works only' do
      expect(found(nil)).to contain_exactly(public_work.noid)
    end

    it 'adds the Works shared with a read group' do
      expect(found(reader.nuid)).to contain_exactly(public_work.noid, group_work.noid)
    end

    it 'adds the Works a group may only edit' do
      expect(found(staff.nuid)).to contain_exactly(public_work.noid, staff_work.noid)
    end

    it "adds a depositor's own private Work" do
      expect(found(depositor.nuid)).to contain_exactly(public_work.noid, deposited.noid)
    end

    it 'shows an admin everything' do
      expect(found(admin.nuid))
        .to contain_exactly(public_work.noid, group_work.noid, staff_work.noid, deposited.noid)
    end
  end

  describe 'what never appears' do
    let!(:public_work) { work('Public') }
    let!(:gone)        { work('Gone', tombstoned: true) }

    it 'drops tombstoned Works, even for an admin' do
      expect(found(admin.nuid)).to contain_exactly(public_work.noid)
    end

    it 'drops FileSets, Blobs, Delegates and the curation containers from a browse' do
      BlobCreator.call(work_id: public_work.noid, original_filename: 'example.bin',
                       path: Rails.root.join('spec/fixtures/files/example.bin').to_s)
      featured = CollectionCreator.call(parent_id: community.noid)
      featured.featured = true
      Atlas.persister.save(resource: featured)

      get '/resources/search', headers: signed_auth_headers(admin.nuid), params: { per_page: 100 }
      rows = response.parsed_body['results']
      expect(rows.pluck('klass').uniq).to all(be_in(SearchQuery::TYPES))
      expect(rows.pluck('noid')).not_to include(featured.noid)
    end
  end

  describe 'unfinished deposits' do
    let!(:unfinished) { work('Unfinished', depositor: depositor.nuid, in_progress: true) }

    it 'hides them from other readers' do
      expect(found(reader.nuid)).not_to include(unfinished.noid)
    end

    it 'shows them to their depositor' do
      expect(found(depositor.nuid)).to include(unfinished.noid)
    end

    it 'shows them to staff' do
      expect(found(staff.nuid)).to include(unfinished.noid)
    end

    it 'flags them in the row' do
      get '/resources/search', params: { q: 'zeppelin' }, headers: signed_auth_headers(depositor.nuid)
      row = response.parsed_body['results'].find { |r| r['noid'] == unfinished.noid }
      expect(row['in_progress']).to be(true)
    end
  end

  describe 'type' do
    let!(:public_work) { work('Public') }

    it 'narrows to one type' do
      expect(found(nil, 'zeppelin', type: 'Collection')).to be_empty
      expect(found(nil, 'zeppelin', type: 'Work')).to contain_exactly(public_work.noid)
    end
  end
end
