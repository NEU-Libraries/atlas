# frozen_string_literal: true

require 'rails_helper'

# Companion to controller_envelope_emission_spec: the resource controllers wire
# AuditEventWriter (via the Auditable concern) into the content / metadata /
# permissions / lifecycle / file paths the structural services never covered.
# Each example drives a controller action and asserts the provenance row(s) it
# leaves. Admin auth (NUID 000000004) is injected by the default auth helper,
# so @nuid is present and audit! fires. AuditEvent is plain ActiveRecord, so it
# rides the per-example transaction — no manual cleanup beyond the Valkyrie wipe.
RSpec.describe 'Controller audit emission' do
  after { Atlas.persister.wipe! }

  let(:actor) { '000000004' }

  describe WorksController, type: :controller do
    render_views

    # Public root: the permissions example below grants a public read, which the
    # containment rule allows only under a public container.
    let(:community)  { public_community! }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }
    let(:work)       { WorkCreator.call(parent_id: collection.noid) }

    it 'metadata_update (permissions) writes a permissions row with before/after ACL' do
      patch :update,
            params: { id: work.noid, metadata: { permissions: { read: ['public'], edit: [], edit_users: ['000000009'] } } },
            as:     :json

      row = AuditEvent.for_resource(work.id).find_by(action: 'update', change_type: 'permissions')
      expect(row).not_to be_nil
      expect(row.action).to eq('update')
      expect(row.payload.dig('after', 'read')).to include('public')
      expect(row.payload.dig('after', 'edit_users')).to include('000000009')
      # before is the pre-edit ACL — different from after (no public read yet).
      expect(row.payload['before']).not_to eq(row.payload['after'])
    end

    it 'suppresses a no-op permissions write whose effective ACL is unchanged (Fix B)' do
      work # force creation up front (no actor on the WorkCreator let -> no events)
      # The Work inherits { read: [public], edit: [staff] } from the tree;
      # re-submitting the same effective ACL (the setter re-prepends staff)
      # changes nothing.
      expect do
        patch :update,
              params: { id: work.noid, metadata: { permissions: { read: ['public'], edit: [], edit_users: [] } } },
              as:     :json
      end.not_to change { AuditEvent.for_resource(work.id).count }

      expect(response).to have_http_status(:ok)
      expect(AuditEvent.for_resource(work.id).where(change_type: 'permissions')).to be_empty
    end

    # Embargo rides the same audited slice as the grants, so set / change /
    # clear each leave a row — nothing else in Atlas records that the release
    # date moved, or who moved it.
    describe 'embargo transitions' do
      def patch_embargo(date, **overrides)
        acl = { read: ['public'], edit: [], edit_users: [], embargo: date }.merge(overrides)
        patch :update, params: { id: work.noid, metadata: { permissions: acl } }, as: :json
      end

      def permissions_rows
        AuditEvent.for_resource(work.id).where(change_type: 'permissions').order(:created_at)
      end

      it 'records setting, changing, and clearing the release date' do
        patch_embargo('2027-12-31')
        patch_embargo('2028-06-30')
        patch_embargo('')

        moves = permissions_rows.map { |row| row.payload.values_at('before', 'after').pluck('embargo') }
        expect(moves.length).to eq(3)
        expect(moves[0][0]).to be_nil
        expect(moves[0][1]).to start_with('2027-12-31')
        expect(moves[1][0]).to start_with('2027-12-31')
        expect(moves[1][1]).to start_with('2028-06-30')
        expect(moves[2][0]).to start_with('2028-06-30')
        expect(moves[2][1]).to be_nil
      end

      it 'leaves the grant keys untouched when only the embargo moved' do
        patch_embargo('2027-12-31')

        row     = permissions_rows.first
        changed = row.payload['after'].reject { |key, value| row.payload['before'][key] == value }
        expect(changed.keys).to eq(['embargo'])
      end

      it 'folds a simultaneous grant change into one event, not two' do
        expect { patch_embargo('2027-12-31', edit_users: ['000000009']) }
          .to change { permissions_rows.count }.by(1)

        row = permissions_rows.last
        expect(row.payload.dig('after', 'edit_users')).to include('000000009')
        expect(row.payload.dig('after', 'embargo')).to    start_with('2027-12-31')
      end

      it 'still suppresses a re-save that leaves the release date alone' do
        patch_embargo('2027-12-31')
        expect { patch_embargo('2027-12-31') }.not_to change { permissions_rows.count }
      end
    end

    it 'binary_update writes a metadata row sourced from MODS' do
      patch :update,
            params: { id:     work.noid,
                      binary: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) },
            as:     :json

      row = AuditEvent.for_resource(work.id).find_by(action: 'update', change_type: 'metadata')
      expect(row.payload['source']).to eq('mods')
    end

    it 'tombstone and restore write lifecycle rows' do
      post :tombstone, params: { id: work.noid }, as: :json
      post :restore,   params: { id: work.noid }, as: :json

      lifecycle = AuditEvent.for_resource(work.id).where(change_type: 'lifecycle').pluck(:action)
      expect(lifecycle).to contain_exactly('tombstone', 'restore')
    end

    it 'complete writes a lifecycle row (restore/complete are no longer dead verbs)' do
      post :complete, params: { id: work.noid }, as: :json

      row = AuditEvent.for_resource(work.id).find_by(action: 'complete')
      expect(row).not_to be_nil
      expect(row.change_type).to eq('lifecycle')
    end

    it 'records the On-Behalf-Of operator as on_behalf_of_nuid under acting-as' do
      # Acting-as rides a signed obo claim now (the On-Behalf-Of header is ignored
      # on the assertion path): admin operator (actor) acting as 000000123.
      request.headers['Authorization'] = "Bearer #{DefaultAuthHeaders.assertion_for(actor, obo: '000000123')}"
      patch :update,
            params: { id:     work.noid,
                      binary: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) },
            as:     :json

      row = AuditEvent.for_resource(work.id).find_by(action: 'update', change_type: 'metadata')
      expect(row.actor_nuid).to eq(actor)
      expect(row.on_behalf_of_nuid).to eq('000000123')
    end
  end

  describe CollectionsController, type: :controller do
    render_views

    let(:community)  { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }

    it 'binary_update and tombstone/restore emit for Collections too' do
      patch :update,
            params: { id:     collection.noid,
                      binary: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) },
            as:     :json
      post  :tombstone, params: { id: collection.noid }, as: :json
      post  :restore,   params: { id: collection.noid }, as: :json

      rows = AuditEvent.for_resource(collection.id)
      expect(rows.where(change_type: 'metadata').count).to eq(1)
      expect(rows.where(change_type: 'lifecycle').pluck(:action)).to contain_exactly('tombstone', 'restore')
      expect(rows.pluck(:resource_type).uniq).to eq(['Collection'])
    end
  end

  describe CommunitiesController, type: :controller do
    render_views

    let(:community) { CommunityCreator.call }

    it 'binary_update and tombstone/restore emit for Communities too' do
      patch :update,
            params: { id:     community.noid,
                      binary: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) },
            as:     :json
      post  :tombstone, params: { id: community.noid }, as: :json
      post  :restore,   params: { id: community.noid }, as: :json

      rows = AuditEvent.for_resource(community.id)
      expect(rows.where(change_type: 'metadata').count).to eq(1)
      expect(rows.where(change_type: 'lifecycle').pluck(:action)).to contain_exactly('tombstone', 'restore')
      expect(rows.pluck(:resource_type).uniq).to eq(['Community'])
    end

    # A root Community is created without passing through Permissions#permissions=
    # (there is no parent ACL to copy), so its embargo attribute is still nil when
    # the Permissions tab is first saved — where the setter's blank normalization
    # turns it into ''. That step is not a rights change and must emit nothing.
    it 'writes no permissions row when a root Community first saves a blank embargo' do
      community.edit_groups = [Permissions::STAFF_EDIT_GROUP]
      Atlas.persister.save(resource: community)
      expect(community.embargo_release_date).to be_nil

      expect do
        patch :update,
              params: { id:       community.noid,
                        metadata: { permissions: { read: [], edit: [Permissions::STAFF_EDIT_GROUP], edit_users: [] } } },
              as:     :json
      end.not_to change { AuditEvent.for_resource(community.id).where(change_type: 'permissions').count }

      expect(response).to have_http_status(:ok)
    end
  end

  describe BlobsController, type: :controller do
    render_views

    let(:community)    { CommunityCreator.call }
    let(:collection)   { CollectionCreator.call(parent_id: community.noid) }
    let(:work)         { WorkCreator.call(parent_id: collection.noid) }
    let(:fixture_path) { Rails.root.join('spec/fixtures/files/example.png').to_s }

    it 'create / update / destroy write file rows hung off the parent Work' do
      post :create, params: { work_id: work.noid, original_filename: 'example.png',
                              binary: Rack::Test::UploadedFile.new(fixture_path, 'image/png') }, as: :json
      blob_noid = response.parsed_body.dig('blob', 'id')

      patch  :update,  params: { id: blob_noid, binary: Rack::Test::UploadedFile.new(fixture_path, 'image/png') }, as: :json
      delete :destroy, params: { id: blob_noid }, as: :json

      rows = AuditEvent.for_resource(work.id).where(change_type: 'file')
      expect(rows.pluck(:action)).to contain_exactly('add_file', 'replace_file', 'remove_file')
      expect(rows.pluck(:resource_type).uniq).to eq(['Work'])
      expect(rows.where(action: 'add_file').first.payload['blob_noid']).to eq(blob_noid)
      expect(rows.where(action: 'remove_file').first.payload['blob_noid']).to eq(blob_noid)
    end
  end
end
