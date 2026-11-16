# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WorkFullText do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  def stored_metadata(resource)
    Valkyrie::Persistence::Postgres::ORM::Resource.find(resource.id.to_s).metadata
  end

  it 'reads back through Work#full_text, and a second store replaces the first' do
    described_class.store(work_id: work.id, text: 'first')
    described_class.store(work_id: work.id, text: 'second')

    expect(Work.find(work.noid).full_text).to eq('second')
    expect(described_class.where(work_id: work.id.to_s).count).to eq(1)
  end

  it 'deletes the row when the text is blank' do
    described_class.store(work_id: work.id, text: 'some text')
    described_class.store(work_id: work.id, text: '')

    expect(described_class.exists?(work_id: work.id.to_s)).to be(false)
    expect(Work.find(work.noid).full_text).to be_nil
  end

  # The point of the table: a save must not rewrite the text inside the row.
  it 'never lands in the Work row, even across a save' do
    described_class.store(work_id: work.id, text: 'body text')
    saved = Atlas.persister.save(resource: Work.find(work.noid))

    expect(stored_metadata(saved)).not_to have_key('full_text')
  end

  it 'answers nil for a Work that has no id yet' do
    expect(Work.new.full_text).to be_nil
  end

  it 'goes with the Work when the Work row is deleted' do
    described_class.store(work_id: work.id, text: 'body text')
    Atlas.persister.delete(resource: Work.find(work.noid))

    expect(described_class.exists?(work_id: work.id.to_s)).to be(false)
  end
end
