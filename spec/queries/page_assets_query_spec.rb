# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PageAssetsQuery do
  after { Atlas.persister.wipe! }

  # A page's assets sit at two containment levels: the page's own member Blobs,
  # and the members of a :derivative FileSet nested under it (where per-page
  # IIIF Delegates land). Built through the persister so the fixture is exactly
  # the shape being queried, with no creator side effects in the way.
  let!(:master) { Atlas.persister.save(resource: Blob.new(use: Role.original_file.name)) }
  let!(:service) do
    Atlas.persister.save(
      resource: Delegate.new(use: Role.service_file.name, uri: 'https://iiif.test/one')
    )
  end
  let!(:thumbnail) do
    Atlas.persister.save(
      resource: Delegate.new(use: Role.thumbnail_image.name, uri: 'https://iiif.test/thumb')
    )
  end
  let!(:nested) do
    Atlas.persister.save(
      resource: FileSet.new(type: Classification.derivative.name, member_ids: [service.id, thumbnail.id])
    )
  end
  let!(:page_one) do
    Atlas.persister.save(
      resource: FileSet.new(type: Classification.image.name, member_ids: [master.id, nested.id])
    )
  end
  let!(:page_two) { Atlas.persister.save(resource: FileSet.new(type: Classification.image.name)) }

  subject(:assets) { described_class.call(file_sets: [page_one, page_two]) }

  it 'keys the result by page FileSet' do
    expect(assets.keys).to contain_exactly(page_one.id.to_s, page_two.id.to_s)
  end

  it "flattens a nested derivative FileSet's members onto the page" do
    expect(assets.fetch(page_one.id.to_s).map(&:noid)).to eq([master.noid, service.noid])
  end

  it 'excludes an asset whose role is not downloadable' do
    expect(assets.fetch(page_one.id.to_s).map(&:noid)).not_to include(thumbnail.noid)
  end

  it 'returns an empty list for a page with no assets' do
    expect(assets.fetch(page_two.id.to_s)).to eq([])
  end

  it 'matches the per-page read it replaced' do
    unbatched = page_one.children
                        .flat_map { |c| c.is_a?(FileSet) ? Atlas.query.find_members(resource: c).to_a : [c] }
                        .select { |m| Role.downloadable?(m.use) }

    expect(assets.fetch(page_one.id.to_s).map(&:noid)).to eq(unbatched.map(&:noid))
  end

  it 'costs the same whether one page is asked for or several' do
    one  = count_queries { described_class.call(file_sets: [page_one]) }
    many = count_queries { described_class.call(file_sets: [page_one, page_two]) }

    expect(many.size).to eq(one.size)
  end

  it 'returns {} for no pages' do
    expect(described_class.call(file_sets: [])).to eq({})
  end
end
