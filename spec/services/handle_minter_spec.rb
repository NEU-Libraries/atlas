# frozen_string_literal: true

require 'rails_helper'

RSpec.describe HandleMinter do
  let!(:community) { Atlas.persister.save(resource: Community.new) }
  let!(:home)      { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
  let!(:work)      { Atlas.persister.save(resource: Work.new(a_member_of: home.id)) }

  let(:public_base) { 'https://repository.example.edu' }

  # A configured client that mints without touching the network.
  let(:client) do
    instance_double(HandleClient, configured?: true).tap do |double|
      allow(double).to receive(:mint) { |suffix, **| "DRSDEV/#{suffix}" }
    end
  end

  def mint(target = work, **overrides)
    described_class.call(work: target, client: client, public_base: public_base, **overrides)
  end

  it 'records "<prefix>/<noid>" on the Work' do
    mint

    expect(Work.find(work.id).handle).to eq("DRSDEV/#{work.noid}")
  end

  it 'points the handle at the public Work page' do
    mint

    expect(client).to have_received(:mint)
      .with(work.noid, url: "https://repository.example.edu/works/#{work.noid}")
  end

  it 'tolerates a trailing slash on the configured public base' do
    described_class.call(work: work, client: client, public_base: 'https://repository.example.edu/')

    expect(client).to have_received(:mint)
      .with(work.noid, url: "https://repository.example.edu/works/#{work.noid}")
  end

  it 'mints once — a second call leaves the existing handle alone' do
    mint
    mint(Work.find(work.id))

    expect(client).to have_received(:mint).once
  end

  it 'does nothing when no handle server is configured' do
    inert = instance_double(HandleClient, configured?: false)

    described_class.call(work: work, client: inert, public_base: public_base)

    expect(Work.find(work.id).handle).to be_nil
  end

  it 'does nothing when there is no public base to point a handle at' do
    described_class.call(work: work, client: client, public_base: nil)

    expect(Work.find(work.id).handle).to be_nil
  end

  # The whole point of the service: /complete is load-bearing, so a handle
  # server that is down must leave the Work finalized and unminted, never
  # raise into the request.
  it 'swallows a handle-server failure and leaves the Work unminted' do
    failing = instance_double(HandleClient, configured?: true)
    allow(failing).to receive(:mint).and_raise(HandleClient::Error, 'connection refused')

    expect { described_class.call(work: work, client: failing, public_base: public_base) }
      .not_to raise_error
    expect(Work.find(work.id).handle).to be_nil
  end

  it 'carries the handle into the OCFL preservation envelope' do
    mint

    payload = Work.find(work.id).graph_payload
    expect(payload[:handle]).to eq("DRSDEV/#{work.noid}")
    expect(payload[:schema_version]).to eq(5)
  end

  # The resource attribute reaches the API and the Work page. MODS is what gets
  # exported, versioned, edited and harvested, so the identifier has to land
  # there too or it reaches none of them.
  describe 'the MODS hdl identifier' do
    # Built through WorkCreator rather than the bare persister the examples
    # above use, because only that path gives the Work the descriptive-metadata
    # FileSet a MODS write needs.
    let(:described) { WorkCreator.call(parent_id: home.noid) }

    def identifier_of(resource)
      Nokogiri::XML(Work.find(resource.id).mods_xml)
              .at_xpath("/mods:mods/mods:identifier[@type='hdl']", NEU::MODS::NAMESPACE)
    end

    def set_identifier!(resource, value)
      doc = Nokogiri::XML(resource.mods_xml)
      doc.at_xpath("/mods:mods/mods:identifier[@type='hdl']", NEU::MODS::NAMESPACE).content = value
      resource.mods_xml = doc.to_s
    end

    def mods_versions(resource)
      Work.find(resource.id).mods_blob.file_identifiers.size
    end

    it 'writes the bare handle into the document' do
      mint(described)

      expect(identifier_of(described).text).to eq("DRSDEV/#{described.noid}")
    end

    it 'keeps the displayLabel the rest of DRS renders the row from' do
      mint(described)

      expect(identifier_of(described)['displayLabel']).to eq('Permanent URL')
    end

    # neu-mods projects identifier[@type='hdl'] onto permanent_url, so the JSON
    # access copy fills from this one write. Nothing derives it separately.
    it 'fills permanent_url on the JSON access copy' do
      mint(described)

      expect(Work.find(described.id).mods.permanent_url).to eq("DRSDEV/#{described.noid}")
    end

    it 'adds the identifier to a document that has none' do
      stripped = Nokogiri::XML(described.mods_xml)
      stripped.at_xpath("/mods:mods/mods:identifier[@type='hdl']", NEU::MODS::NAMESPACE).remove
      described.mods_xml = stripped.to_s

      mint(described)

      expect(identifier_of(described).text).to eq("DRSDEV/#{described.noid}")
    end

    # Every write appends an OCFL version to the descriptive metadata, so a
    # document that already says this must not be written again.
    it 'writes no new version when the document already carries the handle' do
      set_identifier!(described, "DRSDEV/#{described.noid}")
      versions = mods_versions(described)

      mint(described)

      expect(mods_versions(described)).to eq(versions)
    end

    # The reconciliation runs on every call, not only on the call that mints,
    # so a Work minted before this existed still gets its identifier.
    it 'records the identifier for a Work that was minted earlier' do
      described.handle = "DRSDEV/#{described.noid}"
      already = Atlas.persister.save(resource: described)

      mint(already)

      expect(identifier_of(already).text).to eq("DRSDEV/#{already.noid}")
      expect(client).not_to have_received(:mint)
    end

    # A v1 record migrated in under prefix 2047 whose `handle` was never set
    # mints a second identifier here. Both handles resolve, so the document
    # keeps the one it has: a preservation copy does not discard a true
    # statement to make room for another.
    it 'leaves an identifier it did not mint in place' do
      set_identifier!(described, '2047/D20000001')

      mint(described)

      expect(identifier_of(described).text).to eq('2047/D20000001')
      expect(Work.find(described.id).handle).to eq("DRSDEV/#{described.noid}")
    end

    # The handle is registered on an external service the moment the client
    # returns, and nothing here could re-derive that binding — so the resource
    # save has to survive a document that cannot take the write. A Work with no
    # descriptive-metadata FileSet is exactly that case.
    it 'leaves the Work minted when there is no document to write to' do
      expect { mint }.not_to raise_error
      expect(Work.find(work.id).handle).to eq("DRSDEV/#{work.noid}")
    end
  end
end
