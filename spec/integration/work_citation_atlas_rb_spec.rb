# frozen_string_literal: true

require 'rails_helper'

# atlas_rb — AtlasRb::Work.citation wraps WorksController#citation, which
# Cerberus reads for a Work page's Google Scholar tags. Exercised through the
# live server so the CSL-JSON shape a consumer reads, the read gate, the
# tombstone and the 404 → nil are proven against the real endpoint.
RSpec.describe 'Work citation via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { ATLAS_RB_SERVER_ADMIN_NUID }
  let(:collection) { CollectionCreator.call(parent_id: public_community!.noid) }
  let!(:reader) do
    User.create!(email: 'citation-reader@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000782', name: 'Doe, Reader', role: :standard, groups: [])
  end

  def work(visibility, mods: nil)
    work = WorkCreator.call(parent_id: collection.noid)
    work.public_send(visibility)
    work = Atlas.persister.save(resource: work)
    Work.find(work.noid).mods_xml = file_fixture(mods).read if mods
    work
  end

  it 'gives a reader the CSL-JSON item as a Mash, read the way the binding documents' do
    cited = work(:publicize, mods: 'work-mods.xml')

    citation = AtlasRb::Work.citation(cited.noid, nuid: reader.nuid)
    expect(citation).to be_a(AtlasRb::Mash)
    expect(citation.id).to eq(cited.noid)
    expect(citation.type).to eq('song')
    expect(citation.title).to start_with("What's New")
    expect(citation.author.map(&:literal)).to all(be_a(String).and(be_present))
    expect(citation.issued.dig('date-parts', 0)).to eq([2017, 9, 19])
    expect(citation.keyword).to be_a(String)
    expect(citation.keyword.split(', ')).to include('Emergency management', 'Planning')
  end

  it 'leaves out a key the record does not give, so a consumer reads it with &.' do
    citation = AtlasRb::Work.citation(work(:publicize).noid, nuid: reader.nuid)

    expect(citation.keys).to include('id', 'type', 'title')
    expect(citation.keys).not_to include('issued', 'author', 'keyword')
    expect(citation.issued&.dig('date-parts', 0, 0)).to be_nil
  end

  it 'returns nil for a Work that does not exist' do
    expect(AtlasRb::Work.citation('doesnotexist', nuid: reader.nuid)).to be_nil
  end

  it 'raises ResourceError 403 for a caller who cannot read the Work' do
    hidden = work(:privatize)

    expect { AtlasRb::Work.citation(hidden.noid, nuid: reader.nuid) }
      .to raise_error(AtlasRb::ResourceError) { |error| expect(error.status).to eq(403) }
  end

  it 'raises TombstonedError for a tombstoned Work below the admin tiers, and serves an admin' do
    suppressed = work(:publicize)
    tombstoned = Work.find(suppressed.noid)
    tombstoned.tombstone(by: admin_nuid)
    Atlas.persister.save(resource: tombstoned)

    expect { AtlasRb::Work.citation(suppressed.noid, nuid: reader.nuid) }
      .to raise_error(AtlasRb::TombstonedError) { |error| expect(error.work_suppressed?).to be(true) }
    expect(AtlasRb::Work.citation(suppressed.noid, nuid: admin_nuid).id).to eq(suppressed.noid)
  end
end
