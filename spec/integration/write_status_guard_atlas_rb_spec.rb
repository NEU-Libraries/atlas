# frozen_string_literal: true

require 'rails_helper'

# atlas_rb 1.9.4's write-path status guard (`Resource.write_resource`), driven
# over real HTTP so the wire condition is Atlas's own and not a stub.
#
# The symptom it replaces: a write to an id Atlas does not hold raised
# `JSON::ParserError: unexpected end of input`, because Atlas answers
# `head :not_found` — a 404 with an empty body — and the bindings parsed the
# body without looking at the status. An operator whose manifest carried a PID
# from another environment saw that message once per row, naming neither the
# verb nor the object.
#
# The read half already returned a clean nil (`fetch_resource`), and keeps
# doing so; a write raises instead, because "there is nothing there" cannot
# answer a request for a change.
RSpec.describe 'Write-path status guard via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { '000000004' }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:public_community) do
    c = CommunityCreator.call
    c.publicize
    Atlas.persister.save(resource: c)
  end
  let(:public_collection) { CollectionCreator.call(parent_id: public_community.noid) }
  let(:mods_path)  { Rails.root.join('spec/fixtures/files/work-mods.xml').to_s }
  let(:fixture)    { Rails.root.join('spec/fixtures/files/example.bin').to_s }
  let(:missing)    { 'doesnotexist9' }

  describe 'a write to an id Atlas does not hold' do
    it 'raises NotFoundError from Work.update, naming the verb and path' do
      expect { AtlasRb::Work.update(missing, mods_path, nuid: admin_nuid) }
        .to raise_error(AtlasRb::NotFoundError) do |error|
          expect(error.status).to eq(404)
          expect(error.message).to include('PATCH', "/works/#{missing}")
        end
    end

    it 'raises NotFoundError from Work.metadata' do
      expect { AtlasRb::Work.metadata(missing, { 'title' => 'Nope' }, nuid: admin_nuid) }
        .to raise_error(AtlasRb::NotFoundError)
    end

    it 'raises NotFoundError from Collection.metadata' do
      expect { AtlasRb::Collection.metadata(missing, { 'title' => 'Nope' }, nuid: admin_nuid) }
        .to raise_error(AtlasRb::NotFoundError)
    end

    it 'raises NotFoundError from Community.update' do
      expect { AtlasRb::Community.update(missing, mods_path, nuid: admin_nuid) }
        .to raise_error(AtlasRb::NotFoundError)
    end

    it 'raises NotFoundError from FileSet.update' do
      expect { AtlasRb::FileSet.update(missing, fixture, nuid: admin_nuid) }
        .to raise_error(AtlasRb::NotFoundError)
    end

    it 'raises NotFoundError from Blob.rollback' do
      expect { AtlasRb::Blob.rollback(missing, 'v1', nuid: admin_nuid) }
        .to raise_error(AtlasRb::NotFoundError)
    end

    # NotFoundError subclasses ResourceError, so a caller that only wants
    # "the write failed" rescues the parent and still gets the status.
    it 'is rescuable as a ResourceError' do
      expect { AtlasRb::Work.metadata(missing, { 'title' => 'Nope' }, nuid: admin_nuid) }
        .to raise_error(AtlasRb::ResourceError)
    end
  end

  describe 'the paths the guard must not disturb' do
    it 'still returns the parsed payload for a write that lands' do
      work = WorkCreator.call(parent_id: public_collection.noid)
      expect(work.read_groups).to include('public') # inherited from the container

      updated = AtlasRb::Work.metadata(work.noid, { 'permissions' => { 'read' => [] } },
                                       nuid: admin_nuid)

      expect(updated['work']['id']).to eq(work.noid)
      expect(Work.find(work.noid).read_groups).not_to include('public')
    end

    it 'keeps a read on a missing id a clean nil' do
      expect(AtlasRb::Work.find(missing, nuid: admin_nuid)).to be_nil
    end

    # A 410 is a returnable body, not an error: an Idempotency-Key replay whose
    # Work has since been tombstoned answers 410 WITH the tombstone, and the
    # caller reads `tombstoned`. Same treatment the read path gives it.
    it 'returns the tombstone body on a replay of a tombstoned resource' do
      key   = SecureRandom.uuid
      first = AtlasRb::Work.create(collection.noid, idempotency_key: key, nuid: admin_nuid)
      AtlasRb::Work.tombstone(first['id'], nuid: admin_nuid)

      replay = AtlasRb::Work.create(collection.noid, idempotency_key: key, nuid: admin_nuid)

      expect(replay['id']).to eq(first['id'])
      expect(replay['tombstoned']).to be true
    end

    # Atlas refuses a tombstone that would orphan live members with a 422 whose
    # envelope the middleware deliberately passes through. The tombstone binding
    # returns the raw response and never parsed, so the guard leaves it alone.
    it 'leaves the tombstone refusal a raw response to read' do
      work = WorkCreator.call(parent_id: collection.noid)

      response = AtlasRb::Collection.tombstone(collection.noid, nuid: admin_nuid)

      expect(work).to be_present
      expect(response.status).to eq(422)
      expect(JSON.parse(response.body)['code']).to eq('has_live_children')
    end
  end
end
