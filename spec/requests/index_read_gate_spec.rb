# frozen_string_literal: true

require 'rails_helper'

# Who may read an object's Solr document or search explanation; the two share
# one gate. default_auth: false because the admin default passes every check
# and would prove nothing about the gate.
RSpec.describe 'The Solr debugging gate', type: :request, default_auth: false do
  let(:reader_group) { 'northeastern:drs:test-readers' }

  let!(:admin) { ensure_default_admin! }
  let!(:delegate) { make_user('000000042', :privileged, [Permissions::ADMIN_GROUP, reader_group]) }
  let!(:reader)   { make_user('000000002', :standard, [reader_group]) }

  let(:community)  { public_community! }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  # Readable by the reader group and nobody else outside staff.
  let!(:shared_work) { work(read_groups: [reader_group]) }
  # Readable by staff alone, which the delegate here is not in.
  let!(:closed_work) { work(read_groups: []) }

  after { Atlas.persister.wipe! }

  def make_user(nuid, role, groups)
    User.create!(email: "#{nuid}@example.invalid", password: SecureRandom.hex(16),
                 nuid: nuid, role: role, groups: groups)
  end

  def work(read_groups:)
    w = WorkCreator.call(parent_id: collection.noid)
    w.read_groups = read_groups
    Atlas.persister.save(resource: w)
  end

  {
    'the Solr document'      => ->(noid) { "/resources/#{noid}/solr" },
    'the search explanation' => ->(noid) { "/resources/#{noid}/search_explanation?q=anything" }
  }.each do |endpoint, path_for|
    describe endpoint do
      define_method(:read) do |noid, headers|
        get path_for.call(noid), headers: headers
        response
      end

      it 'lets an admin read it for any object' do
        expect(read(closed_work.noid, signed_auth_headers(admin.nuid))).to have_http_status(:ok)
      end

      it 'lets a delegated admin read it for an object they can read' do
        expect(read(shared_work.noid, signed_auth_headers(delegate.nuid))).to have_http_status(:ok)
      end

      it 'refuses a delegated admin an object they cannot read' do
        expect(read(closed_work.noid, signed_auth_headers(delegate.nuid))).to have_http_status(:forbidden)
        expect(response.parsed_body['action']).to eq('read')
      end

      it 'refuses a reader who is not an admin' do
        expect(read(shared_work.noid, signed_auth_headers(reader.nuid))).to have_http_status(:forbidden)
        expect(response.parsed_body['action']).to eq('read_index')
      end

      # Hyperion signs in with a read-only personal token, so the verb must be
      # on the read-only allowlist.
      it "accepts a delegated admin's read-only token" do
        payload = Warden::JWTAuth::PayloadUserHelper.payload_for_user(delegate, :user).merge('aud' => nil)
        payload['read_only'] = true
        token = Warden::JWTAuth::TokenEncoder.new.call(payload)

        expect(read(shared_work.noid, 'Authorization' => "Bearer #{token}")).to have_http_status(:ok)
      end
    end
  end
end
