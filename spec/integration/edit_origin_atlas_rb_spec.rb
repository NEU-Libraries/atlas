# frozen_string_literal: true

require 'rails_helper'

# atlas_rb's `origin:` keyword on the three MODS upload bindings, end to end
# over the wire into the audit event Cerberus's history card reads.
#
# The gap it closes: Cerberus's simple Metadata form, its Advanced tab and its
# raw XML editor all make the identical `update` call, so every MODS change was
# recorded as "MODS document" and a curator could not tell a merge of a few
# owned fields from a hand-replacement of the whole document. `origin` is the
# caller's own assertion of which surface it was; Atlas stores it and never
# branches on it.
#
# Driven through the live server on purpose — the value has to survive
# multipart serialization to be worth anything, and a controller spec that
# hands the parameter straight to the action never tests that.
RSpec.describe 'MODS edit origin via atlas_rb', :atlas_rb_server do
  # Audit reads are admin-only, and an audit row is written only for an
  # authenticated non-guest actor.
  let(:admin_nuid) { '000000004' }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:mods_path)  { Rails.root.join('spec/fixtures/files/work-mods.xml').to_s }

  def metadata_event(id)
    AtlasRb::Resource.history(id, nuid: admin_nuid)['events']
                     .find { |e| e['action'] == 'update' && e['change_type'] == 'metadata' }
  end

  it 'records the origin beside source on a Work update' do
    work = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
    AtlasRb::Work.update(work['id'], mods_path, nuid: admin_nuid, origin: 'xml_editor')

    expect(metadata_event(work['id'])['payload'])
      .to include('source' => 'mods', 'origin' => 'xml_editor')
  end

  it 'records the origin on a Collection update' do
    child = AtlasRb::Collection.create(collection.noid, nuid: admin_nuid)
    AtlasRb::Collection.update(child['id'], mods_path, nuid: admin_nuid, origin: 'metadata_form')

    expect(metadata_event(child['id'])['payload'])
      .to include('source' => 'mods', 'origin' => 'metadata_form')
  end

  it 'records the origin on a Community update' do
    child = AtlasRb::Community.create(nuid: admin_nuid)
    AtlasRb::Community.update(child['id'], mods_path, nuid: admin_nuid, origin: 'advanced_form')

    expect(metadata_event(child['id'])['payload'])
      .to include('source' => 'mods', 'origin' => 'advanced_form')
  end

  # The compatibility half, and the reason the key is omitted rather than sent
  # empty: a host that never passes `origin` must keep producing the event
  # every pre-existing row looks like, so Cerberus's renderer can fall back on
  # the key's absence.
  it 'omits the key entirely when the caller passes no origin' do
    work = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
    AtlasRb::Work.update(work['id'], mods_path, nuid: admin_nuid)

    payload = metadata_event(work['id'])['payload']
    expect(payload).to include('source' => 'mods')
    expect(payload).not_to have_key('origin')
  end
end
