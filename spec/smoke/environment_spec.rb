# frozen_string_literal: true

require 'rails_helper'

# Small in surface, deliberately full-fat: a real Postgres write, a real Solr
# index, a real OCFL object on disk, and a real HTTP round trip through the API.
# It answers one question — is this checkout wired up correctly? — and leaves
# "is the code correct" to the full suite, which CI runs on every push.
#
# Each example stands in for a failure that has cost a debugging session, and
# each is written to fail with its own cause rather than as one of a hundred
# unrelated red examples:
#
#   database  a worker's database is missing or its schema is behind, so every
#             persist fails on a table that is not there.
#   solr      the run is pointed at a core that does not exist, or at another
#             worker's; writes 404 and reads come back empty, which looks like
#             a data problem rather than a configuration one.
#   storage   the OCFL root is unwritable or holds raced state from a killed
#             run, which surfaces as Errno::ENOENT several frames into fsync.
#   request   the response renders end to end, so a broken jbuilder partial or
#             a bad route fails here rather than in the first request spec that
#             happens to run.
#
# Tagged :smoke so `rake smoke` can run this alone.
RSpec.describe 'Environment smoke', :smoke, type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  it 'persists a resource to Postgres and reads it back by NOID' do
    expect(Work.find(work.noid).noid).to eq(work.noid)
  end

  it 'indexes a new Work into the core this run owns' do
    # Queried by NOID rather than by keyword: a keyword search would depend on
    # the field configuration and on this Work landing on page one of a store
    # the rest of the suite has also written to.
    docs = RSolr.connect(url: SolrCore.url)
                .get('select', params: { q: "alternate_ids_ssim:\"id-#{work.noid}\"", rows: 1 })
                .dig('response', 'docs')

    expect(docs.length).to eq(1)
  end

  it 'writes the descriptive MODS into an OCFL object under this run\'s storage root' do
    descriptive_fs = work.children.find do |child|
      child.is_a?(FileSet) && child.type == Classification.descriptive_metadata.name
    end
    blob = descriptive_fs.files.first

    # Tuple (2,2) per OCFL extension 0007 — the first four NOID characters
    # become directory tuples.
    noid = blob.noid
    expect(TestStorage.root.join(noid[0..1], noid[2..3], noid, 'inventory.json')).to exist
  end

  it 'renders a Work through the API' do
    get "/works/#{work.noid}"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('work', 'id')).to eq(work.noid)
  end
end
