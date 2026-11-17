# frozen_string_literal: true

require 'rails_helper'

# A whole MODS document from a caller keeps the Work's handle as its `hdl`
# identifier. See docs/handles.md.
RSpec.describe '#replace_mods_xml' do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:handle)     { "DRSDEV/#{work.noid}" }
  let(:url)        { "https://hdl.handle.net/#{handle}" }

  def hdl_xpath = "/mods:mods/mods:identifier[@type='hdl']"

  def identifiers(resource)
    Nokogiri::XML(resource.class.find(resource.id).mods_xml).xpath(hdl_xpath, NEU::MODS::NAMESPACE).map(&:text)
  end

  def document(resource, identifier: nil)
    doc = Nokogiri::XML(resource.mods_xml)
    doc.xpath(hdl_xpath, NEU::MODS::NAMESPACE).each(&:remove)
    if identifier
      doc.root.add_child(%(<mods:identifier xmlns:mods="http://www.loc.gov/mods/v3" type="hdl">#{identifier}</mods:identifier>))
    end
    doc.to_s
  end

  def with_handle(resource)
    Atlas.persister.save(resource: Work.find(resource.id).tap { |w| w.handle = handle })
  end

  describe 'on a Work with a handle' do
    before { with_handle(work) }

    it 'adds the identifier a document leaves out' do
      work.replace_mods_xml(document(work))
      expect(identifiers(work)).to eq([url])
    end

    it 'replaces a bare handle with the resolver URL' do
      work.replace_mods_xml(document(work, identifier: handle))
      expect(identifiers(work)).to eq([url])
    end

    it 'keeps an identifier naming a different handle' do
      work.replace_mods_xml(document(work, identifier: 'https://hdl.handle.net/2047/d20000001'))
      expect(identifiers(work)).to eq(['https://hdl.handle.net/2047/d20000001'])
    end

    it 'reads the handle Postgres holds, not the caller copy' do
      stale = Work.find(work.id).tap { |w| w.handle = nil }
      stale.replace_mods_xml(document(work))
      expect(identifiers(work)).to eq([url])
    end
  end

  it 'stores the document as sent on a Work with no handle' do
    work.replace_mods_xml(document(work))
    expect(identifiers(work)).to be_empty
  end

  it 'stores the document as sent on a Collection' do
    collection.replace_mods_xml(document(collection))
    expect(identifiers(collection)).to be_empty
  end

  describe 'PUT /resources/:id/mods', type: :request do
    it 'keeps the handle when the uploaded document leaves it out' do
      with_handle(work)
      path = Rails.root.join('tmp', "put-mods-#{SecureRandom.hex(4)}.xml")
      File.write(path, document(work))

      put "/resources/#{work.noid}/mods", params: { binary: Rack::Test::UploadedFile.new(path, 'application/xml') }

      expect(response).to have_http_status(:ok)
      expect(identifiers(work)).to eq([url])
    ensure
      FileUtils.rm_f(path)
    end
  end
end
