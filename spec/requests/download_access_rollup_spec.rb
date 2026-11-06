# frozen_string_literal: true

require 'rails_helper'

# The download roll-up on a Work's Solr doc must agree with GET
# /works/:id/assets after every write that can change that answer. Each example
# makes one such write to a completed Work, then compares the two.
RSpec.describe 'Download access roll-up', type: :request do
  let(:fixture)    { Rails.root.join('spec/fixtures/files/example.bin') }
  let(:pdf)        { Rails.root.join('spec/fixtures/files/example.pdf') }
  let(:collection) { CollectionCreator.call(parent_id: public_community!.noid) }
  let(:work) do
    work = WorkCreator.call(parent_id: collection.noid)
    work.publicize
    work.in_progress = false
    Atlas.persister.save(resource: work)
  end

  after { Atlas.persister.wipe! }

  def rollup
    doc = Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{work.id}"), fl: 'has_downloads_bsi,download_read_groups_ssim' }
    ).dig('response', 'docs').first
    [doc['has_downloads_bsi'], Array(doc['download_read_groups_ssim']).sort]
  end

  # The roll-up as /assets gives it to the admin caller, who sees each gate.
  def from_assets
    get "/works/#{work.noid}/assets"
    assets = response.parsed_body
    [assets.any?, assets.flat_map { |asset| asset['permission'] }.uniq.sort]
  end

  def expect_rollup(listed, groups)
    expect(rollup).to eq([listed, groups.sort])
    expect(rollup).to eq(from_assets)
  end

  def add_file(path = fixture, name: 'a.bin')
    post '/files', params: { work_id: work.noid, original_filename: name, binary: Rack::Test::UploadedFile.new(path) }
    expect(response).to have_http_status(:ok).or have_http_status(:created)
    response.parsed_body.dig('blob', 'id')
  end

  it 'reports no downloads for a Work with no files' do
    expect_rollup(false, [])
  end

  it 'follows a file added to a completed Work' do
    add_file
    expect_rollup(true, ['public'])
  end

  it 'follows a FileSet tombstone and its restore' do
    file_set = Blob.find(add_file).parent

    post "/resources/#{file_set.noid}/tombstone"
    expect_rollup(false, [])

    post "/resources/#{file_set.noid}/restore"
    expect_rollup(true, ['public'])
  end

  # A derivative FileSet is not preserved, so its tombstone writes no storage,
  # and the storage write is what reindexes the Work for the other files.
  it 'follows the tombstone and restore of a derivative FileSet of image renditions' do
    DelegateCreator.call(resource_id: work.id, use: Role.large_image.name, uri: 'https://iiif.example/large.jpg')
    renditions = Work.find(work.noid).children.find { |fs| fs.type == Classification.derivative.name }
    expect_rollup(true, ['public'])

    post "/resources/#{renditions.noid}/tombstone"
    expect_rollup(false, [])

    post "/resources/#{renditions.noid}/restore"
    expect_rollup(true, ['public'])
  end

  it 'follows a replaced file whose new MIME type moves it to a gated tier' do
    patch "/works/#{work.noid}/derivative_permissions", params:  { pdf: ['grp:a'] }.to_json,
                                                        headers: { 'CONTENT_TYPE' => 'application/json' }
    blob = add_file
    expect_rollup(true, ['public'])

    patch "/files/#{blob}", params: { binary: Rack::Test::UploadedFile.new(pdf), original_filename: 'a.pdf' }
    expect(response).to have_http_status(:ok)
    expect_rollup(true, ['grp:a'])
  end

  it 'follows a deleted file' do
    blob = add_file
    delete "/files/#{blob}"
    expect_rollup(false, [])
  end

  it 'follows a deleted FileSet' do
    file_set = Blob.find(add_file).parent
    delete "/file_sets/#{file_set.noid}"
    expect_rollup(false, [])
  end

  it 'follows a deleted derivative FileSet of image renditions' do
    DelegateCreator.call(resource_id: work.id, use: Role.large_image.name, uri: 'https://iiif.example/large.jpg')
    renditions = Work.find(work.noid).children.find { |fs| fs.type == Classification.derivative.name }
    delete "/file_sets/#{renditions.noid}"
    expect_rollup(false, [])
  end

  it 'follows a narrowed Work ACL' do
    add_file
    patch "/resources/#{work.noid}/permissions", params:  { permissions: { read: ['grp:b'] } }.to_json,
                                                 headers: { 'CONTENT_TYPE' => 'application/json' }
    expect(response).to have_http_status(:ok)
    expect_rollup(true, ['grp:b'])
  end

  it 'is not moved by an IIIF service pointer, which /assets does not list' do
    add_file
    page = FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: 1)
    patch "/file_sets/#{page.noid}/iiif_service", params:  { uri: 'https://iiif.example/iiif/3/p.jp2' }.to_json,
                                                  headers: { 'CONTENT_TYPE' => 'application/json' }
    expect(response).to have_http_status(:ok)
    expect_rollup(true, ['public'])
  end
end
